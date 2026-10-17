import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'docker_client.dart';
import 'docker_parse_result.dart';
import 'http_types.dart';
import 'log_resume.dart';
import 'log_time.dart';
import 'models/container.dart';
import 'models/engine_info.dart';
import 'models/events.dart';
import 'models/image.dart';
import 'models/network.dart';
import 'models/pull.dart';
import 'models/stats.dart';
import 'models/system_df.dart';
import 'models/volume.dart';
import 'stdcopy.dart';

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

  /// `GET /containers/{id}/stats?stream=1` (03 §5.6, §7.12 CST-03): one
  /// [ContainerStats] per JSON line.
  Stream<DockerParseResult<ContainerStats>> containerStatsStream(
    String id, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async* {
    final res = await requestLines(
      'GET',
      '/containers/${_seg(id)}/stats',
      query: {'stream': '1'},
      timeout: timeout,
      cancelToken: cancelToken,
    );
    await for (final line in res.body) {
      yield parseContainerStats(_decodeLine(line, 'stats').value);
    }
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

  /// `GET /containers/{id}/logs` demultiplexed into lines (03 §5.6).
  /// [tty] comes from inspect `Config.Tty`; the framing is cross-checked
  /// with the response `Content-Type` when the API is at least 1.42.
  Future<DockerResponse<Stream<LogLine>>> containerLogLines(
    String id, {
    required bool tty,
    bool follow = true,
    bool stdout = true,
    bool stderr = true,
    bool timestamps = true,
    int? tail,
    LogTimestamp? since,
    LogTimestamp? until,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await containerLogsRaw(
      id,
      follow: follow,
      stdout: stdout,
      stderr: stderr,
      timestamps: timestamps,
      tail: tail,
      since: since,
      until: until,
      timeout: timeout,
      cancelToken: cancelToken,
    );
    final choice = resolveLogFraming(
      negotiated: apiVersion,
      tty: tty,
      contentType: res.headers.value('Content-Type'),
    );
    final frames = choice.framing == LogFraming.raw
        ? rawLogFrames(res.body)
        : demuxStdcopy(res.body);
    var lines = splitLogLines(frames);
    // 03 §5.6: `since` is inclusive, so a resumed stream re-sends the
    // boundary line; drop it up to and including the last delivered one.
    if (since != null && timestamps) {
      lines = dropInclusiveSinceLines(lines, since);
    }
    return DockerResponse<Stream<LogLine>>(
      statusCode: res.statusCode,
      reasonPhrase: res.reasonPhrase,
      headers: res.headers,
      body: lines,
    );
  }

  /// `POST /containers/{id}/start` (03 §7.12 CTR-02).
  Future<void> startContainer(
    String id, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _action(
    'POST',
    '/containers/${_seg(id)}/start',
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /containers/{id}/stop?t=<seconds>` (03 §7.12 CTR-02).
  Future<void> stopContainer(
    String id, {
    Duration? t,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _action(
    'POST',
    '/containers/${_seg(id)}/stop',
    query: {if (t != null) 't': '${t.inSeconds}'},
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /containers/{id}/restart?t=<seconds>` (03 §7.12 CTR-02).
  Future<void> restartContainer(
    String id, {
    Duration? t,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _action(
    'POST',
    '/containers/${_seg(id)}/restart',
    query: {if (t != null) 't': '${t.inSeconds}'},
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /containers/{id}/pause` (03 §7.12 CTR-05).
  Future<void> pauseContainer(
    String id, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _action(
    'POST',
    '/containers/${_seg(id)}/pause',
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /containers/{id}/unpause` (03 §7.12 CTR-05).
  Future<void> unpauseContainer(
    String id, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _action(
    'POST',
    '/containers/${_seg(id)}/unpause',
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
  }) => _action(
    'POST',
    '/containers/${_seg(id)}/kill',
    query: {'signal': signal.name.toUpperCase()},
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
  }) => _action(
    'DELETE',
    '/containers/${_seg(id)}',
    query: {
      'v': volumes ? '1' : '0',
      'force': force ? '1' : '0',
      'link': link ? '1' : '0',
    },
    timeout: timeout,
    cancelToken: cancelToken,
  );

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

  /// `GET /images/{name}/json` (03 §7.14 IMG-01, IMG-04).
  Future<DockerParseResult<ImageInspect>> inspectImage(
    String name, {
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    final res = await request(
      'GET',
      '/images/${_seg(name)}/json',
      timeout: timeout,
      cancelToken: cancelToken,
    );
    return parseImageInspect(_decodeBuffered(res.body, 'image inspect').value);
  }

  /// `DELETE /images/{name}?force=&noprune=` (03 §7.14 IMG-02).
  Future<void> removeImage(
    String name, {
    bool force = false,
    bool noprune = false,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) => _action(
    'DELETE',
    '/images/${_seg(name)}',
    query: {'force': force ? '1' : '0', 'noprune': noprune ? '1' : '0'},
    timeout: timeout,
    cancelToken: cancelToken,
  );

  /// `POST /images/create?fromImage=&tag=` (03 §5.6, §7.14 IMG-03):
  /// concatenated JSON progress values keyed by layer id. Closing the
  /// stream cancels the pull on the daemon.
  Stream<DockerParseResult<PullProgress>> pullImage(
    String fromImage, {
    String? tag,
    String? platform,
    Map<String, String>? headers,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async* {
    final res = await requestJsonValues(
      'POST',
      '/images/create',
      query: {
        'fromImage': fromImage,
        if (tag != null) 'tag': tag,
        if (platform != null) 'platform': platform,
      },
      headers: headers,
      timeout: timeout,
      cancelToken: cancelToken,
    );
    await for (final value in res.body) {
      yield parsePullProgress(value);
    }
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
  /// [type] limits the work to one object type.
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

  /// `GET /events` (03 §5.6, §7.12 DKE-02): one parsed event per line,
  /// each with its own warnings. [since] resumes after a reconnect; the
  /// caller re-lists everything when the gap exceeds
  /// [eventGapThreshold].
  Stream<DockerParseResult<DockerEvent>> events({
    LogTimestamp? since,
    LogTimestamp? until,
    Map<String, Object?>? filters,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async* {
    final res = await requestLines(
      'GET',
      '/events',
      query: {
        if (since != null) 'since': '${since.seconds}',
        if (until != null) 'until': '${until.seconds}',
      },
      filters: filters,
      timeout: timeout,
      cancelToken: cancelToken,
    );
    await for (final line in res.body) {
      yield parseDockerEvent(
        _decodeLine(line, 'event').value,
        expectEventV2: gates.usesEventV2,
      );
    }
  }

  Future<void> _action(
    String method,
    String path, {
    Map<String, String>? query,
    Duration? timeout,
    DockerCancelToken? cancelToken,
  }) async {
    await request(
      method,
      path,
      query: query,
      timeout: timeout,
      cancelToken: cancelToken,
    );
  }
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

DockerParseResult<Object?> _decodeLine(String line, String what) {
  try {
    return DockerParseResult(jsonDecode(line));
  } catch (e) {
    return DockerParseResult(null, ['malformed JSON $what line: $e']);
  }
}
