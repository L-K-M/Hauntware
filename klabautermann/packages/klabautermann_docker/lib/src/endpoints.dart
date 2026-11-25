import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'docker_client.dart';
import 'docker_parse_result.dart';
import 'duplex.dart';
import 'errors.dart';
import 'http_types.dart';
import 'json_reader.dart';
import 'log_resume.dart';
import 'log_time.dart';
import 'models/container.dart';
import 'models/container_top.dart';
import 'models/engine_info.dart';
import 'models/exec.dart';
import 'models/image.dart';
import 'models/image_history.dart';
import 'models/network.dart';
import 'models/stats.dart';
import 'models/system_df.dart';
import 'models/volume.dart';
import 'stdcopy.dart';

/// One Engine API mutation as data (ARC-09): [method], the unversioned
/// [path] and the [query]. The typed client methods build one and send
/// it, and the engine's Docker planners build their `ApiStep`s from the
/// same functions, so a previewed request and the request that runs are
/// one definition. [DockerClient.request] adds the version prefix.
final class DockerRequestSpec {
  DockerRequestSpec(this.method, this.path, Map<String, String> query)
    : query = Map.unmodifiable(query);

  final String method;
  final String path;
  final Map<String, String> query;
}

/// `POST /containers/{id}/start` (03 §7.12 CTR-02).
DockerRequestSpec startContainerRequest(String id) =>
    DockerRequestSpec('POST', '/containers/${_seg(id)}/start', const {});

/// `POST /containers/{id}/stop?t=<seconds>` (03 §7.12 CTR-02); no `t`
/// when [t] is null.
DockerRequestSpec stopContainerRequest(String id, {Duration? t}) =>
    DockerRequestSpec('POST', '/containers/${_seg(id)}/stop', {
      if (t != null) 't': '${t.inSeconds}',
    });

/// `POST /containers/{id}/restart?t=<seconds>` (03 §7.12 CTR-02); no
/// `t` when [t] is null.
DockerRequestSpec restartContainerRequest(String id, {Duration? t}) =>
    DockerRequestSpec('POST', '/containers/${_seg(id)}/restart', {
      if (t != null) 't': '${t.inSeconds}',
    });

/// `POST /containers/{id}/pause` (03 §7.12 CTR-05).
DockerRequestSpec pauseContainerRequest(String id) =>
    DockerRequestSpec('POST', '/containers/${_seg(id)}/pause', const {});

/// `POST /containers/{id}/unpause` (03 §7.12 CTR-05).
DockerRequestSpec unpauseContainerRequest(String id) =>
    DockerRequestSpec('POST', '/containers/${_seg(id)}/unpause', const {});

/// `POST /containers/{id}/kill?signal=` (03 §7.12 CTR-05, §8.8). The
/// signal is a name, never an enum value the caller forgot to map: the
/// engine's plans send the bare name (`TERM`), while the client sends
/// its [DockerSignal]'s `SIG`-prefixed name.
DockerRequestSpec killContainerRequest(String id, {String? signal}) =>
    DockerRequestSpec('POST', '/containers/${_seg(id)}/kill', {
      'signal': ?signal,
    });

/// `DELETE /containers/{id}?v=&force=&link=` (03 §7.12 CTR-06). [link]
/// is omitted when null, which is what the engine's plans send; the
/// client always sends it, as `0` unless asked for.
DockerRequestSpec removeContainerRequest(
  String id, {
  bool volumes = false,
  bool force = false,
  bool? link,
}) => DockerRequestSpec('DELETE', '/containers/${_seg(id)}', {
  'v': volumes ? '1' : '0',
  'force': force ? '1' : '0',
  if (link != null) 'link': link ? '1' : '0',
});

/// `DELETE /images/{name}?force=&noprune=` (03 §7.14 IMG-02).
DockerRequestSpec removeImageRequest(
  String name, {
  bool force = false,
  bool noprune = false,
}) => DockerRequestSpec('DELETE', '/images/${_seg(name)}', {
  'force': force ? '1' : '0',
  'noprune': noprune ? '1' : '0',
});

/// Typed endpoint helpers over the versioned [DockerClient] (03 §5.6,
/// §5.8, §7.12 to §7.16). Every parser is tolerant: malformed daemon
/// input becomes a warning, not a throw. HTTP failures still surface as
/// the typed exceptions of [DockerClient].
extension DockerEndpoints on DockerClient {
  // --- containers ------------------------------------------------------

  /// `GET /containers/json` (03 §7.12 CTR-01). Sizes are only requested
  /// when [sizes] is set, because `size=1` is expensive.
  Future<DockerParseResult<List<ContainerSummary>>> listContainers({
    bool all = true,
    bool sizes = false,
    Map<String, Object?>? filters,
    int? limit,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/containers/json',
      query: {
        if (all) 'all': '1',
        if (sizes) 'size': '1',
        if (limit != null) 'limit': '$limit',
      },
      filters: filters,
      timeout: timeout,
      cancelToken: cancelToken,
    );
    final decoded = _decodeBuffered(res.body, '/containers/json');
    if (decoded.value is! List) {
      return DockerParseResult(const <ContainerSummary>[], [
        ...decoded.warnings,
        'container list is not a JSON array',
      ]);
    }
    return parseContainerSummaries(decoded.value);
  }

  /// `GET /containers/{id}/json` (03 §7.12 CTR-03).
  Future<DockerParseResult<ContainerInspect>> inspectContainer(
    String id, {
    bool sizes = false,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/containers/${_seg(id)}/json',
      query: {if (sizes) 'size': '1'},
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseContainerInspect(_decodeBuffered(res.body, 'inspect').value);
  }

  /// `GET /containers/{id}/top` (03 §7.12 CTR-10): the container's
  /// processes as `ps` lists them with [psArgs], or with the daemon's
  /// default `-ef` when null. A container that is not running answers
  /// 409.
  Future<DockerParseResult<ContainerTop>> containerTop(
    String id, {
    String? psArgs,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/containers/${_seg(id)}/top',
      query: {'ps_args': ?psArgs},
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseContainerTop(_decodeBuffered(res.body, 'container top').value);
  }

  /// `GET /containers/{id}/stats?stream=false&one-shot=true` (03 §5.6,
  /// §7.12 CST-01). The one-shot `precpu_stats` is not meaningful, so CPU
  /// percent is computed from two samples, not here.
  Future<DockerParseResult<ContainerStats>> containerStatsOneShot(
    String id, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/containers/${_seg(id)}/stats',
      query: {'stream': 'false', 'one-shot': 'true'},
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseContainerStats(_decodeBuffered(res.body, 'stats').value);
  }

  /// `GET /containers/{id}/logs` as raw bytes (03 §5.6, §7.12 CTX-01).
  /// The caller resolves the framing with [resolveLogFraming] and the
  /// `Content-Type` header, then feeds [demuxStdcopy] or [rawLogFrames].
  /// [since] is an inclusive bound; use [dropInclusiveSince] to remove the
  /// re-sent boundary line.
  Future<DockerResponse<Stream<List<int>>>> containerLogsRaw(
    String id, {
    bool follow = true,
    bool stdout = true,
    bool stderr = true,
    bool timestamps = true,
    int? tail,
    LogTimestamp? since,
    LogTimestamp? until,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => requestBytes(
    'GET',
    '/containers/${_seg(id)}/logs',
    query: {
      'follow': follow ? '1' : '0',
      'stdout': stdout ? '1' : '0',
      'stderr': stderr ? '1' : '0',
      'timestamps': timestamps ? '1' : '0',
      if (tail != null) 'tail': '$tail',
      if (since != null) 'since': since.sinceQuery,
      if (until != null) 'until': until.sinceQuery,
    },
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /containers/{id}/start` (03 §7.12 CTR-02).
  Future<void> startContainer(
    String id, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _send(
    startContainerRequest(id),
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /containers/{id}/stop?t=<seconds>` (03 §7.12 CTR-02).
  Future<void> stopContainer(
    String id, {
    Duration? t,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _send(
    stopContainerRequest(id, t: t),
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /containers/{id}/restart?t=<seconds>` (03 §7.12 CTR-02).
  Future<void> restartContainer(
    String id, {
    Duration? t,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _send(
    restartContainerRequest(id, t: t),
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /containers/{id}/pause` (03 §7.12 CTR-05).
  Future<void> pauseContainer(
    String id, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _send(
    pauseContainerRequest(id),
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /containers/{id}/unpause` (03 §7.12 CTR-05).
  Future<void> unpauseContainer(
    String id, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _send(
    unpauseContainerRequest(id),
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /containers/{id}/kill?signal=` (03 §7.12 CTR-05). The signal
  /// is an enum, never a free string (03 §8.8).
  Future<void> killContainer(
    String id, {
    DockerSignal signal = DockerSignal.sigkill,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _send(
    killContainerRequest(id, signal: signal.name.toUpperCase()),
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `DELETE /containers/{id}?v=&force=&link=` (03 §7.12 CTR-06). The
  /// caller applies the ownership and protected-target checks and the
  /// typed confirmation first.
  Future<void> removeContainer(
    String id, {
    bool volumes = false,
    bool force = false,
    bool link = false,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _send(
    removeContainerRequest(id, volumes: volumes, force: force, link: link),
    timeout: timeout,
    cancelToken: cancelToken,
  );

  // --- exec ------------------------------------------------------------

  /// `POST /containers/{id}/exec` (03 §5.7, §7.13 CTX-07, CTX-08):
  /// creates an exec of [cmd] with stdout and stderr attached, stdin too
  /// when [stdin] is set, and returns its id. [consoleSize] is sent from
  /// API 1.42, where exec create gained it; below, the caller resizes
  /// after the start.
  Future<String> createExec(
    String containerId,
    List<String> cmd, {
    bool tty = false,
    bool stdin = true,
    String? user,
    String? workingDir,
    ExecConsoleSize? consoleSize,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    if (cmd.isEmpty) throw ArgumentError.value(cmd, 'cmd', 'is empty');
    final res = await request(
      'POST',
      '/containers/${_seg(containerId)}/exec',
      json: {
        'AttachStdin': stdin,
        'AttachStdout': true,
        'AttachStderr': true,
        'Tty': tty,
        'Cmd': cmd,
        'User': ?user,
        'WorkingDir': ?workingDir,
        if (consoleSize != null && gates.hasExecConsoleSize)
          'ConsoleSize': [consoleSize.rows, consoleSize.columns],
      },
      timeout: timeout,
      cancelToken: cancelToken,
    );
    final decoded = _decodeBuffered(res.body, 'exec create').value;
    final id = decoded is Map ? decoded['Id'] : null;
    if (id is! String || id.isEmpty) {
      throw const DockerProtocolException('exec create returned no id');
    }
    return id;
  }

  /// `POST /exec/{id}/start` (03 §5.7): hijacks the connection with
  /// `Upgrade: tcp`. With [tty] the duplex carries raw terminal bytes;
  /// without it the daemon multiplexes stdout and stderr, which
  /// `demuxStdcopy` splits. Stdin EOF is the duplex's half-close.
  Future<DockerResponse<HijackedDuplex>> startExec(
    String execId, {
    bool tty = false,
    ExecConsoleSize? consoleSize,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => requestHijack(
    'POST',
    '/exec/${_seg(execId)}/start',
    json: {
      'Detach': false,
      'Tty': tty,
      if (consoleSize != null && gates.hasExecConsoleSize)
        'ConsoleSize': [consoleSize.rows, consoleSize.columns],
    },
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /exec/{id}/resize?h=<rows>&w=<columns>` (03 §5.7): rows first,
  /// as Docker takes them (c2 R15).
  Future<void> resizeExec(
    String execId,
    ExecConsoleSize size, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _send(
    DockerRequestSpec('POST', '/exec/${_seg(execId)}/resize', {
      'h': '${size.rows}',
      'w': '${size.columns}',
    }),
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `GET /exec/{id}/json` (03 §5.7): whether the exec runs, and its exit
  /// code once it has ended.
  Future<DockerParseResult<ExecInspect>> inspectExec(
    String execId, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/exec/${_seg(execId)}/json',
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseExecInspect(_decodeBuffered(res.body, 'exec inspect').value);
  }

  // --- images ----------------------------------------------------------

  /// `GET /images/json` (03 §7.14 IMG-01). The `Containers` count is read
  /// only from API 1.51.
  Future<DockerParseResult<List<ImageSummary>>> listImages({
    bool all = false,
    Map<String, Object?>? filters,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/images/json',
      query: {if (all) 'all': '1'},
      filters: filters,
      timeout: timeout,
      cancelToken: cancelToken,
    );
    final decoded = _decodeBuffered(res.body, '/images/json');
    if (decoded.value is! List) {
      return DockerParseResult(const <ImageSummary>[], [
        ...decoded.warnings,
        'image list is not a JSON array',
      ]);
    }
    return parseImageSummaries(
      decoded.value,
      includeContainerCount: gates.hasImageContainersCount,
    );
  }

  /// `GET /images/{name}/json` (03 §7.14 IMG-01, IMG-04); [manifests]
  /// adds the index children (IMG-05), from API 1.48 only.
  Future<DockerParseResult<ImageInspect>> inspectImage(
    String name, {
    bool manifests = false,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/images/${_seg(name)}/json',
      query: {if (manifests && gates.hasImageManifests) 'manifests': '1'},
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseImageInspect(_decodeBuffered(res.body, 'image inspect').value);
  }

  /// `GET /distribution/{name}/json` (03 §7.14 IMG-05, D68): the daemon
  /// asks the registry with its own credentials, resolving the tag with
  /// a `HEAD` and then fetching the manifest, which spends one Docker
  /// Hub pull per call. The update check's last resort only.
  Future<DockerParseResult<DistributionDescriptor>> distributionInspect(
    String name, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/distribution/${_seg(name)}/json',
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseDistributionInspect(
      _decodeBuffered(res.body, 'distribution inspect').value,
    );
  }

  /// `DELETE /images/{name}?force=&noprune=` (03 §7.14 IMG-02).
  Future<void> removeImage(
    String name, {
    bool force = false,
    bool noprune = false,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _send(
    removeImageRequest(name, force: force, noprune: noprune),
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `GET /images/{name}/history` (03 §7.14 IMG-04): the image's layers,
  /// newest first.
  Future<DockerParseResult<List<ImageHistoryEntry>>> imageHistory(
    String name, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/images/${_seg(name)}/history',
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseImageHistory(_decodeBuffered(res.body, 'image history').value);
  }

  // --- networks and volumes -------------------------------------------

  /// `GET /networks` (03 §7.15 DNW-01).
  Future<DockerParseResult<List<NetworkSummary>>> listNetworks({
    Map<String, Object?>? filters,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/networks',
      filters: filters,
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseNetworkSummaries(_decodeBuffered(res.body, '/networks').value);
  }

  /// `GET /networks/{id}` (03 §7.15 DNW-02): one network with the
  /// containers that hold an endpoint on it, which the list leaves out.
  Future<NetworkSummary> inspectNetwork(
    String id, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/networks/${_seg(id)}',
      timeout: timeout,
      cancelToken: cancelToken,
    );
    final decoded = _decodeBuffered(res.body, 'network inspect').value;
    return NetworkSummary.parse(
      JsonReader(asStringMap(decoded is Map ? decoded : const {}), []),
    );
  }

  /// `GET /volumes` (03 §7.15 VOL-01).
  Future<DockerParseResult<List<VolumeSummary>>> listVolumes({
    Map<String, Object?>? filters,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/volumes',
      filters: filters,
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseVolumeSummaries(_decodeBuffered(res.body, '/volumes').value);
  }

  /// `GET /volumes/{name}` (03 §7.15 VOL-02): one volume, as the list
  /// reports it.
  Future<VolumeSummary> inspectVolume(
    String name, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/volumes/${_seg(name)}',
      timeout: timeout,
      cancelToken: cancelToken,
    );
    final decoded = _decodeBuffered(res.body, 'volume inspect').value;
    return VolumeSummary.parse(
      JsonReader(asStringMap(decoded is Map ? decoded : const {}), []),
    );
  }

  // --- engine ----------------------------------------------------------

  /// `GET /info` typed (03 §7.12 DKE-01).
  Future<DockerParseResult<EngineInfo>> engineInfo({
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/info',
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseEngineInfo(_decodeBuffered(res.body, '/info').value);
  }

  /// `GET /system/df` (03 §5.8, §7.1 OV-05): per-type totals and
  /// reclaimable space, read through the negotiated shape gate. Slow on
  /// large hosts, so callers fetch it on demand, apart from the lists.
  /// [type] limits the work to one object type; daemons below API 1.42
  /// ignore it and report every type.
  Future<DockerParseResult<SystemDf>> systemDf({
    SystemDfType? type,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/system/df',
      query: {if (type != null) 'type': type.wireName},
      timeout: timeout,
      cancelToken: cancelToken,
    );
    final decoded = _decodeBuffered(res.body, '/system/df');
    final parsed = parseSystemDf(decoded.value, shape: gates.systemDfShape);
    return DockerParseResult(parsed.value, [
      ...decoded.warnings,
      ...parsed.warnings,
    ]);
  }

  /// Sends [spec] as the versioned request it names.
  Future<void> _send(
    DockerRequestSpec spec, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => request(
    spec.method,
    spec.path,
    query: spec.query,
    timeout: timeout,
    cancelToken: cancelToken,
  );
}

/// The signals accepted by `POST /containers/{id}/kill` (03 §7.12 CTR-05,
/// §8.8: signal names are an enum).
enum DockerSignal {
  sighup,
  sigint,
  sigquit,
  sigkill,
  sigusr1,
  sigusr2,
  sigterm,
  sigstop,
  sigcont,
}

String _seg(String value) => Uri.encodeComponent(value);

DockerParseResult<Object?> _decodeBuffered(Uint8List body, String what) {
  try {
    return DockerParseResult(
      jsonDecode(utf8.decode(body, allowMalformed: true)),
    );
  } catch (e) {
    return DockerParseResult(null, ['malformed JSON from $what: $e']);
  }
}
