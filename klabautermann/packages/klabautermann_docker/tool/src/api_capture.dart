// The capture side of the recorded Docker API corpus (03 §11.1, D21;
// spike S1): seeds a disposable daemon through the Engine API, then
// records each exchange's raw response bytes through the package's own
// DockerHttpClient. capture.sh runs it against rootful daemons in
// privileged containers; never point it at a daemon you care about, as
// it creates containers, an image, a network and a volume there.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_docker/klabautermann_docker.dart';

import 'api_corpus.dart';
import 'unix_duplex.dart';

/// What one capture run needs.
final class CaptureOptions {
  const CaptureOptions({
    required this.socketPath,
    required this.outDir,
    required this.expectApi,
    required this.seedImage,
    this.daemonImage,
    this.run,
    this.wait = const Duration(seconds: 90),
  });

  /// The daemon's Unix socket.
  final String socketPath;

  /// The corpus directory to write; its name is the corpus name.
  final String outDir;

  /// The API maximum the daemon must report (`--expect-api`).
  final ApiVersion expectApi;

  /// `<repository>:<tag>@sha256:<digest>`, pulled by digest.
  final String seedImage;

  /// The daemon's image reference, for SOURCE.md and the manifest.
  final String? daemonImage;

  /// A run identifier for SOURCE.md, such as a CI run URL.
  final String? run;

  /// How long to wait for the socket, and for each seeded state.
  final Duration wait;
}

/// Thrown when the daemon is not the one asked for or a seeding step
/// fails; the message names the step.
final class CaptureException implements Exception {
  const CaptureException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The seeded containers in inspect order. `job` prints the lines, then
/// exits; `paused` is paused; the rest keep running.
const List<String> seededContainers = [
  'web',
  'worker',
  'job',
  'tty',
  'paused',
  'demo-web-1',
  'demo-cache-1',
  'coolify-app',
];

/// Lines `job` prints: half on stdout, half on stderr.
const int jobLines = 2000;

/// The `since` exchange starts this many lines before the end of `job`'s
/// output, which keeps the recording small.
const int _sinceTailLines = 100;

/// Lines kept of the stats stream (the plan's truncation after 2).
const int _statsStreamLines = 2;

/// Seconds between recording the events request and its `until`.
const int _eventsLead = 2;

const String _composeProject = 'demo';
const String _networkName = 'demo_default';
const String _volumeName = 'demo_data';
const String _composeVersion = '5.6.0';

/// Fake, low-entropy secrets: the corpus must show where secrets sit
/// without carrying one (03 §8.9; gitleaks reads the corpus).
const String _fakePassword = 'fixture-password';

enum _Expect { success, refusal, any }

final class _Spec {
  const _Spec(
    this.name,
    this.method,
    this.path, {
    this.query,
    this.expect = _Expect.success,
    this.lines,
    this.json,
    this.hijack = false,
  });

  final String name;
  final String method;
  final String path;
  final Map<String, String>? query;
  final _Expect expect;

  /// The request's JSON body, if any.
  final Object? json;

  /// Hijack the connection (exec start) and record until the daemon
  /// closes it.
  final bool hijack;

  /// Keep only this many body lines, then close the stream.
  final int? lines;

  String get request {
    final q = query;
    if (q == null || q.isEmpty) return '$method $path';
    final encoded = [
      for (final MapEntry(:key, :value) in q.entries)
        '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}',
    ].join('&');
    return '$method $path?$encoded';
  }
}

/// Runs one capture into [CaptureOptions.outDir].
Future<void> runCapture(CaptureOptions options) async {
  final out = Directory(options.outDir);
  if (out.existsSync() && out.listSync().isNotEmpty) {
    throw CaptureException('${options.outDir} is not empty');
  }
  out.createSync(recursive: true);
  final corpus = out.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
  final seed = _SeedReference.parse(options.seedImage);

  final ping = await _waitForPing(options);
  final session = _Session(options.socketPath);
  try {
    final version = await session.json('GET', '/version') as Map;
    final api = ApiVersion.tryParse('${version['ApiVersion']}');
    final minApi = ApiVersion.tryParse('${version['MinAPIVersion']}');
    if (api == null || minApi == null) {
      throw CaptureException('/version names no API range: $version');
    }
    if (api != options.expectApi) {
      throw CaptureException(
        'the daemon serves API $api at most, not ${options.expectApi} '
        '(--expect-api); its version is ${version['Version']}',
      );
    }
    stdout.writeln('daemon ${version['Version']}, API $api (min $minApi)');
    session.apiVersion = api;
    final podman = ping.contains('libpod-api-version');

    final t0 = _unixNow() - 1;
    final seeded = await _seed(session, seed, options, podman: podman);
    final recorder = _Recorder(options.socketPath, out);
    final v = '/${api.pathSegment}';

    // The finite events window, recorded at once with `until` a moment
    // ahead: Podman 5.8 answered an `until` already in the past with at
    // most one event, while both daemons end the stream when `until`
    // arrives.
    final t1 = _unixNow() + _eventsLead;
    final events = _Spec(
      'events',
      'GET',
      '$v/events',
      query: {'since': '$t0', 'until': '$t1'},
    );
    final prerecorded = {
      seeded.follow.spec.name: seeded.follow.entry,
      events.name: await recorder.record(events),
    };

    final info = await session.json('GET', '/info') as Map;
    final entries = <ExchangeEntry>[];
    final specs = [
      const _Spec('ping-head', 'HEAD', '/_ping'),
      const _Spec('ping-get', 'GET', '/_ping'),
      const _Spec('version', 'GET', '/version'),
      _Spec('info', 'GET', '$v/info'),
      _Spec('containers', 'GET', '$v/containers/json', query: {'all': '1'}),
      _Spec(
        'containers-size',
        'GET',
        '$v/containers/json',
        query: {'all': '1', 'size': '1'},
      ),
      for (final name in seededContainers)
        _Spec('inspect-$name', 'GET', '$v/containers/$name/json'),
      _Spec(
        'inspect-missing',
        'GET',
        '$v/containers/klab-missing/json',
        expect: _Expect.refusal,
      ),
      _Spec(
        'stats-oneshot',
        'GET',
        '$v/containers/web/stats',
        query: {'stream': 'false', 'one-shot': 'true'},
      ),
      _Spec(
        'stats-stream',
        'GET',
        '$v/containers/web/stats',
        query: {'stream': '1'},
        lines: _statsStreamLines,
      ),
      _Spec(
        'logs-tail',
        'GET',
        '$v/containers/job/logs',
        query: _logs(tail: 20),
      ),
      _Spec(
        'logs-tail-tty',
        'GET',
        '$v/containers/tty/logs',
        query: _logs(tail: 20),
      ),
      seeded.follow.spec,
      _Spec(
        'logs-since',
        'GET',
        '$v/containers/job/logs',
        query: {..._logs(), 'since': seeded.since},
      ),
      _Spec('images', 'GET', '$v/images/json'),
      _Spec('image-inspect', 'GET', '$v/images/${seed.tagged}/json'),
      _Spec('networks', 'GET', '$v/networks'),
      _Spec('volumes', 'GET', '$v/volumes'),
      _Spec('system-df', 'GET', '$v/system/df'),
      events,
      // Versioned paths around the daemon's range (03 §5.8): one minor
      // below its minimum, one above its maximum, and the client floor.
      // Docker refuses out-of-range versions with 400; whatever a daemon
      // answers is what gets recorded.
      _Spec(
        'below-min',
        'GET',
        '/v${minApi.major}.${minApi.minor - 1}/info',
        expect: _Expect.any,
      ),
      _Spec(
        'above-max',
        'GET',
        '/v${api.major}.${api.minor + 1}/info',
        expect: _Expect.any,
      ),
      _Spec(
        'floor-1.41',
        'GET',
        '/${clientApiFloor.pathSegment}/info',
        expect: _Expect.any,
      ),
    ];
    for (final spec in specs) {
      entries.add(prerecorded[spec.name] ?? await recorder.record(spec));
    }
    entries.addAll(await _recordExec(session, recorder, v, options));

    final manifest = CorpusManifest(
      corpus: corpus,
      capturedAt: DateTime.now().toUtc().toIso8601String(),
      daemon: DaemonFacts(
        runtime: podman ? 'podman' : 'docker',
        version: '${version['Version']}',
        apiVersion: '$api',
        minApiVersion: '$minApi',
        details: {
          'image': ?options.daemonImage,
          'rootless': _rootless(info),
          'operatingSystem': info['OperatingSystem'],
          'osType': info['OSType'],
          'architecture': info['Architecture'],
          'kernelVersion': info['KernelVersion'],
          'cgroupVersion': info['CgroupVersion'],
          'cgroupDriver': info['CgroupDriver'],
          'storageDriver': info['Driver'],
        },
      ),
      images: {
        'seed': options.seedImage,
        'seedId': seeded.seedId,
        'dangling': seeded.danglingId,
      },
      seeded: {
        'containers': seeded.containers,
        'networks': {_networkName: seeded.networkId},
        'volumes': [_volumeName],
        'eventsWindow': {'since': t0, 'until': t1},
      },
      exchanges: entries,
    );
    File('${out.path}/$manifestFileName').writeAsStringSync(manifest.encode());
    File(
      '${out.path}/$sourceFileName',
    ).writeAsStringSync(_sourceNote(manifest, options, podman: podman));

    // The capture must pass its own check: every file parses and agrees
    // with the manifest.
    readCorpus((file) {
      final f = File('${out.path}/$file');
      return f.existsSync() ? f.readAsBytesSync() : null;
    });
    stdout.writeln('wrote ${entries.length} exchanges to ${out.path}');
  } finally {
    // A paused container's frozen processes ignore SIGKILL under cgroup
    // v1, which would leave the daemon's own container unkillable.
    try {
      await session.json('POST', '/containers/paused/unpause');
    } on Object {
      // Not seeded yet, or already gone.
    }
    await session.close();
  }
}

Map<String, String> _logs({int? tail}) => {
  'stdout': '1',
  'stderr': '1',
  'timestamps': '1',
  'tail': ?tail?.toString(),
};

bool _rootless(Map info) =>
    (info['SecurityOptions'] as List?)?.any((o) => '$o'.contains('rootless')) ??
    false;

int _unixNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// `<repository>:<tag>@sha256:<hex>`.
final class _SeedReference {
  const _SeedReference(this.repository, this.tag, this.digest);

  static _SeedReference parse(String ref) {
    final m = RegExp(
      r'^([a-z0-9./-]+):([A-Za-z0-9._-]+)@(sha256:[0-9a-f]{64})$',
    ).firstMatch(ref);
    if (m == null) {
      throw CaptureException(
        '--seed-image must be <repository>:<tag>@sha256:<digest>: $ref',
      );
    }
    return _SeedReference(m[1]!, m[2]!, m[3]!);
  }

  final String repository;
  final String tag;
  final String digest;

  String get tagged => '$repository:$tag';
  String get pinned => '$repository@$digest';
}

/// Retries `_ping` until the daemon answers; returns the lowercase names
/// of its `GET /_ping` response headers.
Future<Set<String>> _waitForPing(CaptureOptions options) async {
  final deadline = DateTime.now().add(options.wait);
  Object? last;
  while (DateTime.now().isBefore(deadline)) {
    final http = DockerHttpClient(
      () => UnixSocketDuplex.connect(options.socketPath),
      maxConnections: 1,
      defaultTimeout: const Duration(seconds: 5),
    );
    try {
      final res = await http.sendBuffered(
        const DockerHttpRequest(method: 'GET', path: '/_ping'),
      );
      return {for (final e in res.headers.entries) e.key.toLowerCase()};
    } catch (e) {
      last = e;
    } finally {
      await http.close();
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw CaptureException(
    'no answer on ${options.socketPath} within ${options.wait}: $last',
  );
}

/// The seeding connection pool: plain requests, nothing recorded.
final class _Session {
  _Session(String socketPath)
    : _http = DockerHttpClient(
        () => UnixSocketDuplex.connect(socketPath),
        defaultTimeout: const Duration(minutes: 2),
      );

  final DockerHttpClient _http;
  ApiVersion apiVersion = clientApiFloor;

  DockerClient get client => DockerClient(_http, apiVersion: apiVersion);

  /// Sends a request; versioned unless [path] is `/version` or starts
  /// with `/v<digit>`. Returns the decoded JSON body, or null when empty.
  Future<Object?> json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final versioned = path != '/version' && !RegExp(r'^/v\d').hasMatch(path);
    try {
      final res = await client.request(
        method,
        path,
        query: query,
        json: body,
        versioned: versioned,
      );
      // Podman answers some actions with a bare newline.
      final text = utf8.decode(res.body).trim();
      if (text.isEmpty) return null;
      return jsonDecode(text);
    } on FormatException catch (e) {
      throw CaptureException('$method $path: not JSON: ${e.source}');
    } on DockerApiException catch (e) {
      throw CaptureException('$method $path: ${e.statusCode} ${e.message}');
    }
  }

  Future<void> close() => _http.close();
}

/// How long a hijacked exchange is read for before the recorder closes
/// it: well past an exec that prints two lines and exits.
const Duration _hijackDrainLimit = Duration(seconds: 30);

/// Records exchanges, each on a connection of its own so that the tap
/// holds exactly one response.
final class _Recorder {
  _Recorder(this._socketPath, this._out);

  final String _socketPath;
  final Directory _out;

  Future<ExchangeEntry> record(_Spec spec) async {
    final raw = await _exchange(spec);
    return _store(spec, raw);
  }

  /// Sends [spec] and returns the response bytes, cut after
  /// [_Spec.lines] lines when set.
  Future<Uint8List> _exchange(_Spec spec) async {
    final tap = ResponseTap();
    final http = DockerHttpClient(
      () => UnixSocketDuplex.connect(_socketPath, onBytes: tap.add),
      maxConnections: 1,
      defaultTimeout: const Duration(minutes: 2),
    );
    final request = DockerHttpRequest(
      method: spec.method,
      path: spec.path,
      query: spec.query,
      json: spec.json,
      upgrade: spec.hijack,
    );
    try {
      final lines = spec.lines;
      if (spec.hijack) {
        final res = await http.sendHijack(request);
        // The daemon has been seen to keep a finished exec's hijacked
        // stream open; the client's timeout only covers the response
        // head, so an unbounded drain hung the whole capture. The output
        // frames come before the exit, and _waitForExec and exec-inspect
        // confirm the exit, so stopping here loses nothing they record.
        // Ignored so that a stream ending in an error after the timeout
        // and the close below is not reported as unhandled.
        final drained = res.body.stream.drain<void>()..ignore();
        await drained.timeout(_hijackDrainLimit, onTimeout: () {});
        await res.body.close();
      } else if (lines == null) {
        await http.sendBuffered(request, maxBytes: 64 * 1024 * 1024);
      } else {
        final res = await http.sendLines(request);
        final got = await res.body.take(lines).length;
        if (got < lines) {
          throw CaptureException('${spec.name}: $got of $lines lines');
        }
      }
    } on DockerApiException {
      // The status is checked below, from the recorded bytes.
    } finally {
      await http.close();
    }
    final raw = tap.bytes;
    final lines = spec.lines;
    if (lines == null) return raw;
    final cut = truncationPoint(raw, lines);
    if (cut == null) {
      throw CaptureException('${spec.name}: cannot cut after $lines lines');
    }
    return Uint8List.sublistView(raw, 0, cut);
  }

  ExchangeEntry _store(_Spec spec, Uint8List raw) {
    final response = parseRecordedResponse(
      raw,
      headRequest: spec.method == 'HEAD',
    );
    final status = response.statusCode;
    // A hijacked request succeeds by switching protocols.
    final ok = status ~/ 100 == 2 || (spec.hijack && status == 101);
    if (spec.expect == _Expect.success && !ok) {
      throw CaptureException(
        '${spec.request}: $status '
        '${utf8.decode(response.body, allowMalformed: true)}',
      );
    }
    if (spec.expect == _Expect.refusal && ok) {
      throw CaptureException('${spec.request}: $status, expected a refusal');
    }
    final entry = ExchangeEntry(
      name: spec.name,
      request: spec.request,
      status: status,
      contentType: response.header('content-type'),
      framing: response.framing,
      truncatedAfterLines: spec.lines,
    );
    File('${_out.path}/${entry.file}').writeAsBytesSync(raw);
    stdout.writeln('  ${entry.name}: $status ${spec.request}');
    return entry;
  }
}

/// The exec exchanges (03 §5.7, CTX-07, CTX-08), last so that nothing
/// recorded before them carries an exec: a non-TTY exec on `web`
/// created, started over the hijacked connection until its process
/// exits, and inspected once it has; then the resize of a TTY exec
/// started detached.
Future<List<ExchangeEntry>> _recordExec(
  _Session s,
  _Recorder recorder,
  String v,
  CaptureOptions options,
) async {
  final create = _Spec(
    'exec-create',
    'POST',
    '$v/containers/web/exec',
    json: const {
      'AttachStdin': false,
      'AttachStdout': true,
      'AttachStderr': true,
      'Tty': false,
      'Cmd': ['sh', '-c', 'echo out; echo err >&2; exit 3'],
    },
  );
  final createRaw = await recorder._exchange(create);
  final createEntry = recorder._store(create, createRaw);
  final id = _execId(createRaw);

  final start = await recorder.record(
    _Spec(
      'exec-start',
      'POST',
      '$v/exec/$id/start',
      json: const {'Detach': false, 'Tty': false},
      hijack: true,
    ),
  );
  await _waitForExec(s, id, options);
  final inspect = await recorder.record(
    _Spec('exec-inspect', 'GET', '$v/exec/$id/json'),
  );

  final tty =
      await s.json(
            'POST',
            '/containers/web/exec',
            body: const {
              'AttachStdin': false,
              'AttachStdout': false,
              'AttachStderr': false,
              'Tty': true,
              'Cmd': ['sleep', '60'],
            },
          )
          as Map;
  final ttyId = '${tty['Id']}';
  await s.json(
    'POST',
    '/exec/$ttyId/start',
    body: const {'Detach': true, 'Tty': true},
  );
  final resize = await recorder.record(
    _Spec(
      'exec-resize',
      'POST',
      '$v/exec/$ttyId/resize',
      query: const {'h': '40', 'w': '120'},
      expect: _Expect.any,
    ),
  );
  return [createEntry, start, inspect, resize];
}

String _execId(Uint8List raw) {
  final body = jsonDecode(utf8.decode(parseRecordedResponse(raw).body));
  final id = body is Map ? body['Id'] : null;
  if (id is! String || id.isEmpty) {
    throw CaptureException('exec-create: no Id in $body');
  }
  return id;
}

/// Waits until exec [id]'s process has exited.
Future<void> _waitForExec(_Session s, String id, CaptureOptions options) async {
  final deadline = DateTime.now().add(options.wait);
  while (DateTime.now().isBefore(deadline)) {
    final inspect = await s.json('GET', '/exec/$id/json') as Map;
    if (inspect['Running'] == false) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw CaptureException('exec $id still runs after ${options.wait}');
}

/// What seeding leaves for the recording.
final class _Seeded {
  const _Seeded({
    required this.seedId,
    required this.danglingId,
    required this.networkId,
    required this.containers,
    required this.follow,
    required this.since,
  });

  final String seedId;
  final String danglingId;
  final String networkId;
  final Map<String, String> containers;

  /// The follow exchange on `job`, recorded while it ran.
  final ({_Spec spec, ExchangeEntry entry}) follow;

  /// A `since=` value about $_sinceTailLines lines before `job`'s end.
  final String since;
}

Future<_Seeded> _seed(
  _Session s,
  _SeedReference seed,
  CaptureOptions options, {
  required bool podman,
}) async {
  stdout.writeln('seeding');
  await _pull(s, seed);
  await s.json(
    'POST',
    '/images/${seed.pinned}/tag',
    query: {'repo': seed.repository, 'tag': seed.tag},
  );
  final image = await s.json('GET', '/images/${seed.tagged}/json') as Map;
  final seedId = '${image['Id']}';

  final network =
      await s.json(
            'POST',
            '/networks/create',
            body: {
              'Name': _networkName,
              'Labels': {
                'com.docker.compose.network': 'default',
                'com.docker.compose.project': _composeProject,
                'com.docker.compose.version': _composeVersion,
              },
            },
          )
          as Map;
  await s.json(
    'POST',
    '/volumes/create',
    body: {
      'Name': _volumeName,
      'Labels': {
        'com.docker.compose.project': _composeProject,
        'com.docker.compose.volume': 'data',
        'com.docker.compose.version': _composeVersion,
      },
    },
  );

  final ids = <String, String>{};
  for (final name in seededContainers) {
    final created =
        await s.json(
              'POST',
              '/containers/create',
              query: {'name': name},
              body: _containerConfig(name, seed.tagged, seedId),
            )
            as Map;
    ids[name] = '${created['Id']}';
  }

  for (final name in ['tty', 'paused', 'demo-web-1', 'demo-cache-1']) {
    await s.json('POST', '/containers/$name/start');
  }
  await s.json('POST', '/containers/coolify-app/start');
  await s.json('POST', '/containers/paused/pause');
  await _waitFor(s, 'paused', options, (i) => _status(i) == 'paused');

  // Follow job from before its first line until it exits.
  await s.json('POST', '/containers/job/start');
  final follow = _Spec(
    'logs-follow',
    'GET',
    '/${s.apiVersion.pathSegment}/containers/job/logs',
    query: {..._logs(), 'follow': '1'},
  );
  final recorder = _Recorder(options.socketPath, Directory(options.outDir));
  final followRaw = await recorder._exchange(follow);
  final followEntry = recorder._store(follow, followRaw);
  await _waitFor(s, 'job', options, (i) => _status(i) == 'exited');
  final since = _sinceFromFollow(followRaw);

  final committed =
      await s.json(
            'POST',
            '/commit',
            query: {'container': 'job', 'comment': 'klabautermann capture'},
          )
          as Map;

  await s.json('POST', '/containers/web/start');
  await s.json('POST', '/containers/worker/start');
  await _waitForHealth(s, 'web', 'healthy', options, podman: podman);
  await _waitForHealth(s, 'worker', 'unhealthy', options, podman: podman);

  return _Seeded(
    seedId: seedId,
    danglingId: '${committed['Id']}',
    networkId: '${network['Id'] ?? network['id']}',
    containers: ids,
    follow: (spec: follow, entry: followEntry),
    since: since,
  );
}

Future<void> _pull(_Session s, _SeedReference seed) async {
  stdout.writeln('pulling ${seed.pinned}');
  try {
    final res = await s.client.requestJsonValues(
      'POST',
      '/images/create',
      query: {'fromImage': seed.repository, 'tag': seed.digest},
    );
    await for (final value in res.body) {
      if (value is Map && (value['error'] ?? value['errorDetail']) != null) {
        throw CaptureException('pull ${seed.pinned}: $value');
      }
    }
  } on DockerApiException catch (e) {
    throw CaptureException('pull ${seed.pinned}: ${e.statusCode} ${e.message}');
  }
}

String? _status(Map inspect) =>
    (inspect['State'] as Map?)?['Status'] as String?;

String? _health(Map inspect) =>
    ((inspect['State'] as Map?)?['Health'] as Map?)?['Status'] as String?;

Future<Map> _waitFor(
  _Session s,
  String container,
  CaptureOptions options,
  bool Function(Map inspect) done, {
  Future<void> Function()? poke,
}) async {
  final deadline = DateTime.now().add(options.wait);
  while (true) {
    final inspect = await s.json('GET', '/containers/$container/json') as Map;
    if (done(inspect)) return inspect;
    if (DateTime.now().isAfter(deadline)) {
      throw CaptureException(
        '$container: no expected state within ${options.wait}: '
        'status ${_status(inspect)}, health ${_health(inspect)}',
      );
    }
    await poke?.call();
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// Waits for [container]'s health [status]. Podman schedules health
/// checks through systemd timers, which a container without systemd
/// lacks; there the libpod endpoint runs each check by hand (recorded in
/// SOURCE.md).
Future<void> _waitForHealth(
  _Session s,
  String container,
  String status,
  CaptureOptions options, {
  required bool podman,
}) async {
  await _waitFor(
    s,
    container,
    options,
    (i) => _health(i) == status,
    poke: podman
        ? () async {
            try {
              await s.client.request(
                'GET',
                '/v5.0.0/libpod/containers/$container/healthcheck',
                versioned: false,
              );
            } on DockerApiException {
              // A failing check answers with an error status on some
              // versions; the state poll decides.
            }
          }
        : null,
  );
}

String _sinceFromFollow(Uint8List raw) {
  final response = parseRecordedResponse(raw);
  // Podman 5.8 sometimes sends one line as two frames, each with its own
  // timestamp, so lines are counted by their newlines.
  final frames = [
    for (final (_, payload) in stdcopyFrames(response.body))
      utf8.decode(payload),
  ];
  final lines = frames.fold(0, (n, f) => n + '\n'.allMatches(f).length);
  if (lines != jobLines) {
    throw CaptureException(
      'logs-follow: $lines lines from job, expected $jobLines',
    );
  }
  final nanos = [
    for (final frame in frames)
      switch (LogTimestamp.tryParse(frame.split(' ').first)) {
        final at? => at.seconds * _nanosPerSecond + at.nanos,
        null => throw CaptureException('logs-follow: no timestamp: $frame'),
      },
  ]..sort();
  // Lines often share a timestamp, and Docker's `since` is inclusive
  // while Podman 5.8 returned nothing for a `since` equal to the last
  // lines' shared timestamp. A value between two distinct timestamps
  // selects the same lines either way.
  var i = nanos.length - _sinceTailLines;
  while (i > 0 && nanos[i] - nanos[i - 1] < 2) {
    i--;
  }
  final since = i == 0 ? nanos.first - 1 : nanos[i - 1] + 1;
  return LogTimestamp(
    since ~/ _nanosPerSecond,
    since % _nanosPerSecond,
  ).sinceQuery;
}

const int _nanosPerSecond = 1000000000;

Map<String, Object?> _composeLabels(String service, String seedId) => {
  'com.docker.compose.project': _composeProject,
  'com.docker.compose.service': service,
  'com.docker.compose.container-number': '1',
  'com.docker.compose.oneoff': 'False',
  // Fixed, obviously synthetic hashes: compose's are SHA-256 hex.
  'com.docker.compose.config-hash': service == 'web'
      ? '0123456789abcdef' * 4
      : 'fedcba9876543210' * 4,
  'com.docker.compose.project.working_dir': '/srv/demo',
  'com.docker.compose.project.config_files': '/srv/demo/compose.yaml',
  'com.docker.compose.image': seedId,
  'com.docker.compose.depends_on': service == 'web'
      ? 'cache:service_started:true'
      : '',
  'com.docker.compose.version': _composeVersion,
};

const Duration _healthInterval = Duration(seconds: 1);
const Duration _healthTimeout = Duration(seconds: 3);

Map<String, Object?> _healthcheck(List<String> test) => {
  'Test': test,
  'Interval': _healthInterval.inMicroseconds * 1000,
  'Timeout': _healthTimeout.inMicroseconds * 1000,
  'Retries': 1,
};

/// `job`: a short pause so the follow attaches first, then the lines.
const String _jobScript =
    'sleep 2; i=1; while [ \$i -le ${jobLines ~/ 2} ]; do '
    'echo "stdout line \$i"; echo "stderr line \$i" >&2; i=\$((i+1)); '
    'done';

Map<String, Object?> _containerConfig(
  String name,
  String image,
  String seedId,
) {
  const sleep = ['sleep', '86400'];
  return switch (name) {
    'web' => {
      'Image': image,
      'Cmd': [
        'sh',
        '-c',
        'mkdir -p /www && echo ok > /www/index.html && '
            'exec httpd -f -p 8080 -h /www',
      ],
      'ExposedPorts': {'8080/tcp': <String, Object?>{}},
      'Healthcheck': _healthcheck([
        'CMD',
        'wget',
        '-q',
        '-O',
        '/dev/null',
        'http://127.0.0.1:8080/',
      ]),
      'Labels': {'org.example.role': 'web'},
    },
    'worker' => {
      'Image': image,
      'Cmd': sleep,
      'Env': ['DB_PASSWORD=$_fakePassword', 'LOG_LEVEL=info'],
      'Healthcheck': _healthcheck([
        'CMD-SHELL',
        'echo worker not ready >&2; exit 1',
      ]),
      'Labels': {
        'org.example.backup':
            'https://fixture:$_fakePassword@backup.example.invalid/demo',
      },
    },
    'job' => {
      'Image': image,
      'Cmd': ['sh', '-c', _jobScript],
    },
    'tty' => {
      'Image': image,
      'Tty': true,
      'Cmd': [
        'sh',
        '-c',
        'echo tty line 1; echo tty line 2; echo tty line 3; '
            'exec sleep 86400',
      ],
    },
    'paused' => {'Image': image, 'Cmd': sleep},
    'demo-web-1' || 'demo-cache-1' => () {
      final service = name == 'demo-web-1' ? 'web' : 'cache';
      return {
        'Image': image,
        'Cmd': sleep,
        'Labels': _composeLabels(service, seedId),
        'HostConfig': {
          'NetworkMode': _networkName,
          if (service == 'cache') 'Binds': ['$_volumeName:/data'],
        },
        'NetworkingConfig': {
          'EndpointsConfig': {
            _networkName: {
              'Aliases': [service],
            },
          },
        },
      };
    }(),
    'coolify-app' => {
      'Image': image,
      'Cmd': sleep,
      'Labels': {
        'coolify.managed': 'true',
        'coolify.name': 'app',
        'coolify.type': 'application',
      },
    },
    _ => throw ArgumentError.value(name, 'name', 'not a seeded container'),
  };
}

String _sourceNote(
  CorpusManifest m,
  CaptureOptions options, {
  required bool podman,
}) {
  final d = m.daemon;
  final engine = podman
      ? 'Podman ${d.version}, Docker-compatible API ${d.apiVersion} '
            '(minimum ${d.minApiVersion})'
      : 'Docker Engine ${d.version}, API ${d.apiVersion} '
            '(minimum ${d.minApiVersion})';
  final b = _WrappingBuffer()
    ..writeln('# Recorded Docker API: ${m.corpus}')
    ..writeln()
    ..writeln(
      'Recorded by `klabautermann_docker/tool/capture_api.dart` (03 '
      '§11.1, D21) from $engine, running '
      '${d.details['rootless'] == true ? 'rootless' : 'rootful'} in a '
      'privileged container of `${options.daemonImage ?? 'unknown'}`, '
      'through its Unix socket, on ${m.capturedAt}'
      '${options.run == null ? '' : ' (${options.run})'}. The daemon '
      'reported ${d.details['operatingSystem']}, kernel '
      '${d.details['kernelVersion']} and cgroup '
      'v${d.details['cgroupVersion']}.',
    )
    ..writeln()
    ..writeln(
      'The tool seeded the daemon through the API first: '
      '`${m.images['seed']}` pulled by digest and tagged; containers '
      '${seededContainers.map((c) => '`$c`').join(', ')} (`web` with a '
      'passing health check, `worker` with a failing one, `job` printing '
      '$jobLines lines on stdout and stderr, `tty` with a TTY, `paused` '
      'paused, a compose project `$_composeProject` of two services, a '
      '`coolify.managed=true` container); the network `$_networkName`; '
      'the volume `$_volumeName`; and a dangling image committed from '
      '`job`. The only secrets are fake and low entropy: '
      '`DB_PASSWORD=$_fakePassword` in `worker`\'s environment and a URL '
      'credential in its labels.',
    );
  if (podman) {
    b
      ..writeln()
      ..writeln(
        'Podman schedules health checks with systemd timers, and its '
        'container runs no systemd, so while waiting for each health '
        'state the tool also ran the check through '
        '`/libpod/containers/{name}/healthcheck`. The `[containers]` '
        'settings of capture_docker_api.sh replace the image\'s nesting '
        'defaults (cgroups disabled, host namespaces), under which a '
        'container can be neither paused nor measured.',
      );
  }
  b
    ..writeln()
    ..writeln(
      'Each `<name>.http` file holds the response bytes exactly as the '
      'daemon sent them: status line, headers and the body with its '
      'chunked framing. `stats-stream` is cut at the end of the chunk '
      'that completes its second line. MANIFEST.json lists the requests '
      'in order; capture.sh\'s check mode compares a fresh capture with '
      'this directory by exchange list, status, content type, header '
      'names, body kind and JSON key paths, never by value.',
    )
    ..writeln()
    ..table('| Exchange | Request | Status |')
    ..table('|---|---|---|');
  for (final e in m.exchanges) {
    b.table('| `${e.name}` | `${e.request}` | ${e.status} |');
  }
  return b.toString();
}

/// Writes Markdown paragraphs wrapped at 72 columns.
final class _WrappingBuffer {
  final StringBuffer _out = StringBuffer();

  void writeln([String text = '']) => _write(text, wrap: true);

  void table(String row) => _write(row, wrap: false);

  void _write(String text, {required bool wrap}) {
    if (!wrap) {
      _out.writeln(text);
      return;
    }
    var line = '';
    for (final word in text.split(' ')) {
      if (line.isNotEmpty && line.length + 1 + word.length > 72) {
        _out.writeln(line);
        line = word;
      } else {
        line = line.isEmpty ? word : '$line $word';
      }
    }
    _out.writeln(line);
  }

  @override
  String toString() => _out.toString();
}
