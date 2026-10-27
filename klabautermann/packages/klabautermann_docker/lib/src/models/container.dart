import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';
import '../masking.dart';
import '../time.dart';

/// Container health state from `State.Health.Status` or the list
/// `Status` text (03 §7.12 CTR-04).
enum HealthStatus {
  none,
  starting,
  healthy,
  unhealthy;

  static HealthStatus? fromName(String? name) => switch (name?.toLowerCase()) {
    'starting' => HealthStatus.starting,
    'healthy' => HealthStatus.healthy,
    'unhealthy' => HealthStatus.unhealthy,
    'none' => HealthStatus.none,
    _ => null,
  };
}

/// One health-check result (`State.Health.Log[]`).
@immutable
final class HealthLog {
  const HealthLog({this.start, this.end, this.exitCode, this.output});

  final DateTime? start;
  final DateTime? end;
  final int? exitCode;
  final String? output;

  static HealthLog parse(JsonReader r) => HealthLog(
    start: dateTimeFromString(r.string('Start')),
    end: dateTimeFromString(r.string('End')),
    exitCode: r.integer('ExitCode'),
    output: r.string('Output'),
  );
}

/// `State.Health` (03 §7.12 CTR-04).
@immutable
final class ContainerHealth {
  const ContainerHealth({
    this.status = HealthStatus.none,
    this.failingStreak,
    this.log = const [],
  });

  final HealthStatus status;
  final int? failingStreak;
  final List<HealthLog> log;

  static ContainerHealth parse(JsonReader r) => ContainerHealth(
    status: HealthStatus.fromName(r.string('Status')) ?? HealthStatus.none,
    failingStreak: r.integer('FailingStreak'),
    log: [
      for (final e in r.list('Log') ?? const <Object?>[])
        if (e is Map) HealthLog.parse(JsonReader(asStringMap(e))),
    ],
  );
}

/// A published or exposed port from `Ports[]` (03 §7.12 CTR-01).
@immutable
final class ContainerPort {
  const ContainerPort({this.ip, this.privatePort, this.publicPort, this.type});

  final String? ip;
  final int? privatePort;
  final int? publicPort;
  final String? type;

  static ContainerPort parse(JsonReader r) => ContainerPort(
    ip: r.string('IP'),
    privatePort: r.integer('PrivatePort'),
    publicPort: r.integer('PublicPort'),
    type: r.string('Type'),
  );

  /// `0.0.0.0:8080->80/tcp`-style label, or just `80/tcp` when unexposed.
  String get label {
    final proto = type ?? 'tcp';
    final priv = privatePort?.toString() ?? '?';
    if (publicPort == null) return '$priv/$proto';
    final host = ip == null ? '' : '${ip!}:';
    return '$host$publicPort->$priv/$proto';
  }
}

/// A mount from the list or inspect `Mounts[]` (03 §7.12 CTR-03).
@immutable
final class ContainerMount {
  const ContainerMount({
    this.type,
    this.name,
    this.source,
    this.destination,
    this.driver,
    this.mode,
    this.rw,
    this.propagation,
  });

  final String? type;
  final String? name;
  final String? source;
  final String? destination;
  final String? driver;
  final String? mode;
  final bool? rw;
  final String? propagation;

  static ContainerMount parse(JsonReader r) => ContainerMount(
    type: r.string('Type'),
    name: r.string('Name'),
    source: r.string('Source'),
    destination: r.string('Destination'),
    driver: r.string('Driver'),
    mode: r.string('Mode'),
    rw: r.boolean('RW'),
    propagation: r.string('Propagation'),
  );
}

/// One container as `GET /containers/json` reports it (03 §7.12 CTR-01).
/// Labels are masked (03 §8.9).
@immutable
final class ContainerSummary {
  const ContainerSummary({
    required this.id,
    this.names = const [],
    this.image,
    this.imageId,
    this.command,
    this.created,
    this.ports = const [],
    this.labels = const {},
    this.state,
    this.status,
    this.health,
    this.mounts = const [],
    this.networkMode,
    this.networks = const {},
    this.sizeRw,
    this.sizeRootFs,
  });

  final String id;
  final List<String> names;
  final String? image;
  final String? imageId;
  final String? command;
  final DateTime? created;
  final List<ContainerPort> ports;
  final Map<String, MaskedValue> labels;
  final String? state;
  final String? status;

  /// From `Health.Status` (API 1.52+) or the `Status` text; null when
  /// neither names a state.
  final HealthStatus? health;
  final List<ContainerMount> mounts;
  final String? networkMode;

  /// Attached networks keyed by network name, with the container IP when
  /// the daemon reports it.
  final Map<String, String> networks;
  final int? sizeRw;
  final int? sizeRootFs;

  /// The display name with the leading slash stripped.
  String? get name {
    if (names.isEmpty) return null;
    final first = names.first;
    return first.startsWith('/') ? first.substring(1) : first;
  }

  /// The compose service name when a Swarm task name is detected
  /// (03 §7.12 CTR-01: parsed defensively).
  String? get swarmServiceName => swarmServiceNameHint(name);

  static ContainerSummary parse(JsonReader r) {
    final netSettings = r.map('NetworkSettings');
    final networks = <String, String>{};
    if (netSettings != null) {
      final netMap = JsonReader(netSettings, r.warnings).map('Networks');
      if (netMap != null) {
        for (final e in netMap.entries) {
          final v = e.value;
          if (v is Map) {
            final ip = JsonReader(
              asStringMap(v),
              r.warnings,
            ).string('IPAddress');
            if (ip != null && ip.isNotEmpty) networks[e.key] = ip;
          }
        }
      }
    }
    final hostConfig = r.map('HostConfig');
    // From API 1.52 the list carries `Health`; older daemons only mark it
    // in the `Status` text.
    final health = r.map('Health');
    final healthName = health == null
        ? null
        : JsonReader(health, r.warnings).string('Status');
    return ContainerSummary(
      id: r.string('Id') ?? '',
      names: r.stringList('Names'),
      image: r.string('Image'),
      imageId: r.string('ImageID'),
      command: r.string('Command'),
      created: dateTimeFromUnix(r.integer('Created')),
      ports: [
        for (final e in r.list('Ports') ?? const <Object?>[])
          if (e is Map)
            ContainerPort.parse(JsonReader(asStringMap(e), r.warnings)),
      ],
      labels: maskedLabels(r.stringMap('Labels')),
      state: r.string('State'),
      status: r.string('Status'),
      health:
          HealthStatus.fromName(healthName) ??
          healthFromStatus(r.string('Status')),
      mounts: [
        for (final e in r.list('Mounts') ?? const <Object?>[])
          if (e is Map)
            ContainerMount.parse(JsonReader(asStringMap(e), r.warnings)),
      ],
      networkMode: hostConfig == null
          ? null
          : JsonReader(hostConfig, r.warnings).string('NetworkMode'),
      networks: networks,
      sizeRw: r.integer('SizeRw'),
      sizeRootFs: r.integer('SizeRootFs'),
    );
  }
}

/// Parses the `GET /containers/json` array (03 §7.12 CTR-01); never
/// throws on daemon input.
DockerParseResult<List<ContainerSummary>> parseContainerSummaries(
  Object? decoded,
) {
  final warnings = <String>[];
  if (decoded is! List) {
    warnings.add('container list is not a JSON array');
    return DockerParseResult(const <ContainerSummary>[], warnings);
  }
  final out = <ContainerSummary>[];
  for (final e in decoded) {
    if (e is Map) {
      out.add(ContainerSummary.parse(JsonReader(asStringMap(e), warnings)));
    } else {
      warnings.add('container list entry is not an object');
    }
  }
  return DockerParseResult(out, warnings);
}

/// Reads `(healthy)`-style markers out of the list `Status` text
/// (03 §7.12 CTR-01).
HealthStatus? healthFromStatus(String? status) {
  if (status == null) return null;
  final lower = status.toLowerCase();
  if (lower.contains('(healthy)')) return HealthStatus.healthy;
  if (lower.contains('(unhealthy)')) return HealthStatus.unhealthy;
  if (lower.contains('(health: starting)')) return HealthStatus.starting;
  return null;
}

/// Swarm task names are `<service>.<slot>.<taskid>`; returns the service
/// name when the pattern is present, else null (03 §7.12 CTR-01).
String? swarmServiceNameHint(String? name) {
  if (name == null) return null;
  final dotted = RegExp(r'^(.+)\.\d+\.[a-z0-9]{25}$').firstMatch(name);
  if (dotted != null) return dotted.group(1);
  final short = RegExp(r'^(.+)\.\d+$').firstMatch(name);
  return short?.group(1);
}

/// One `KEY=VALUE` environment entry with its value masked (03 §8.9).
@immutable
final class EnvVar {
  const EnvVar(this.name, this.value);

  final String name;
  final MaskedValue value;
}

/// Parses a `Config.Env` list, masking values by key.
List<EnvVar> parseEnv(List<String> entries) => [
  for (final e in entries)
    if (e.contains('='))
      EnvVar(e.substring(0, e.indexOf('=')), maskedEnvEntry(e))
    else
      EnvVar(e, MaskedValue.plain('')),
];

/// `State` of an inspected container (03 §7.12 CTR-03, CTR-04, CTR-09).
@immutable
final class ContainerState {
  const ContainerState({
    this.status,
    this.running = false,
    this.paused = false,
    this.restarting = false,
    this.oomKilled = false,
    this.dead = false,
    this.pid,
    this.exitCode,
    this.error,
    this.startedAt,
    this.finishedAt,
    this.health,
  });

  final String? status;
  final bool running;
  final bool paused;
  final bool restarting;
  final bool oomKilled;
  final bool dead;
  final int? pid;
  final int? exitCode;
  final String? error;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final ContainerHealth? health;

  static ContainerState parse(JsonReader r) {
    final health = r.map('Health');
    return ContainerState(
      status: r.string('Status'),
      running: r.boolean('Running') ?? false,
      paused: r.boolean('Paused') ?? false,
      restarting: r.boolean('Restarting') ?? false,
      oomKilled: r.boolean('OOMKilled') ?? false,
      dead: r.boolean('Dead') ?? false,
      pid: r.integer('Pid'),
      exitCode: r.integer('ExitCode'),
      error: r.string('Error'),
      startedAt: dateTimeFromString(r.string('StartedAt')),
      finishedAt: dateTimeFromString(r.string('FinishedAt')),
      health: health == null
          ? null
          : ContainerHealth.parse(JsonReader(health, r.warnings)),
    );
  }
}

/// `HostConfig.RestartPolicy` (03 §7.12 CTR-03).
@immutable
final class ContainerRestartPolicy {
  const ContainerRestartPolicy({this.name, this.maximumRetryCount});

  final String? name;
  final int? maximumRetryCount;

  static ContainerRestartPolicy parse(JsonReader r) => ContainerRestartPolicy(
    name: r.string('Name'),
    maximumRetryCount: r.integer('MaximumRetryCount'),
  );
}

/// `HostConfig.LogConfig` (03 §7.12 CTR-03, DKE-07).
@immutable
final class LogConfig {
  const LogConfig({this.type, this.config = const {}});

  final String? type;
  final Map<String, String> config;

  static LogConfig parse(JsonReader r) =>
      LogConfig(type: r.string('Type'), config: r.stringMap('Config'));
}

/// The inspect `HostConfig` fields the panels use (03 §7.12 CTR-03).
@immutable
final class ContainerHostConfig {
  const ContainerHostConfig({
    this.networkMode,
    this.restartPolicy,
    this.logConfig,
    this.privileged = false,
    this.readonlyRootfs = false,
    this.binds = const [],
    this.memory,
    this.nanoCpus,
    this.pidMode,
    this.autoRemove = false,
    this.capAdd = const [],
  });

  final String? networkMode;
  final ContainerRestartPolicy? restartPolicy;
  final LogConfig? logConfig;
  final bool privileged;
  final bool readonlyRootfs;
  final List<String> binds;
  final int? memory;
  final int? nanoCpus;
  final String? pidMode;
  final bool autoRemove;

  /// The capabilities added past the runtime's default set (DKE-06).
  final List<String> capAdd;

  static ContainerHostConfig parse(JsonReader r) {
    final restart = r.map('RestartPolicy');
    final log = r.map('LogConfig');
    return ContainerHostConfig(
      networkMode: r.string('NetworkMode'),
      restartPolicy: restart == null
          ? null
          : ContainerRestartPolicy.parse(JsonReader(restart, r.warnings)),
      logConfig: log == null
          ? null
          : LogConfig.parse(JsonReader(log, r.warnings)),
      privileged: r.boolean('Privileged') ?? false,
      readonlyRootfs: r.boolean('ReadonlyRootfs') ?? false,
      binds: r.stringList('Binds'),
      memory: r.integer('Memory'),
      nanoCpus: r.integer('NanoCpus'),
      pidMode: r.string('PidMode'),
      autoRemove: r.boolean('AutoRemove') ?? false,
      capAdd: r.stringList('CapAdd'),
    );
  }
}

/// The inspect `Config` fields the panels use; `Env` and `Labels` are
/// masked (03 §8.9).
@immutable
final class ContainerConfig {
  const ContainerConfig({
    this.hostname,
    this.image,
    this.user,
    this.workingDir,
    this.stopSignal,
    this.tty = false,
    this.openStdin = false,
    this.stdinOnce = false,
    this.env = const [],
    this.cmd = const [],
    this.entrypoint = const [],
    this.labels = const {},
    this.healthcheck = const [],
  });

  final String? hostname;
  final String? image;
  final String? user;
  final String? workingDir;
  final String? stopSignal;
  final bool tty;
  final bool openStdin;
  final bool stdinOnce;
  final List<EnvVar> env;
  final List<String> cmd;
  final List<String> entrypoint;
  final Map<String, MaskedValue> labels;

  /// `Healthcheck.Test`, the image's merged with the container's: empty
  /// when neither sets one, `["NONE"]` when the container turns the
  /// image's off (DKE-06).
  final List<String> healthcheck;

  static ContainerConfig parse(JsonReader r) => ContainerConfig(
    hostname: r.string('Hostname'),
    image: r.string('Image'),
    user: r.string('User'),
    workingDir: r.string('WorkingDir'),
    stopSignal: r.string('StopSignal'),
    tty: r.boolean('Tty') ?? false,
    openStdin: r.boolean('OpenStdin') ?? false,
    stdinOnce: r.boolean('StdinOnce') ?? false,
    env: parseEnv(r.stringList('Env')),
    cmd: r.stringList('Cmd'),
    entrypoint: r.stringList('Entrypoint'),
    labels: maskedLabels(r.stringMap('Labels')),
    healthcheck: switch (r.map('Healthcheck')) {
      final check? => JsonReader(check, r.warnings).stringList('Test'),
      null => const [],
    },
  );
}

/// One network attachment from inspect `NetworkSettings.Networks`.
@immutable
final class ContainerNetwork {
  const ContainerNetwork({
    this.ipAddress,
    this.gateway,
    this.macAddress,
    this.networkId,
    this.aliases = const [],
  });

  final String? ipAddress;
  final String? gateway;
  final String? macAddress;
  final String? networkId;
  final List<String> aliases;

  static ContainerNetwork parse(JsonReader r) => ContainerNetwork(
    ipAddress: r.string('IPAddress'),
    gateway: r.string('Gateway'),
    macAddress: r.string('MacAddress'),
    networkId: r.string('NetworkID'),
    aliases: r.stringList('Aliases'),
  );
}

/// Inspect `NetworkSettings` (03 §7.12 CTR-03).
@immutable
final class ContainerNetworkSettings {
  const ContainerNetworkSettings({
    this.networks = const {},
    this.ipAddress,
    this.gateway,
  });

  final Map<String, ContainerNetwork> networks;
  final String? ipAddress;
  final String? gateway;

  static ContainerNetworkSettings parse(JsonReader r) {
    final networks = <String, ContainerNetwork>{};
    final netMap = r.map('Networks');
    if (netMap != null) {
      for (final e in netMap.entries) {
        final v = e.value;
        if (v is Map) {
          networks[e.key] = ContainerNetwork.parse(
            JsonReader(asStringMap(v), r.warnings),
          );
        }
      }
    }
    return ContainerNetworkSettings(
      networks: networks,
      ipAddress: r.string('IPAddress'),
      gateway: r.string('Gateway'),
    );
  }
}

/// One inspected container (`GET /containers/{id}/json`, 03 §7.12
/// CTR-03). No raw JSON is kept: inspect output contains secrets and a
/// raw map would defeat the masking rule of 03 §8.9.
@immutable
final class ContainerInspect {
  const ContainerInspect({
    required this.id,
    this.name,
    this.created,
    this.path,
    this.args = const [],
    this.image,
    this.state,
    this.restartCount,
    this.driver,
    this.platform,
    this.logPath,
    this.hostConfig,
    this.config,
    this.mounts = const [],
    this.networkSettings,
  });

  final String id;
  final String? name;
  final DateTime? created;
  final String? path;
  final List<String> args;
  final String? image;
  final ContainerState? state;
  final int? restartCount;
  final String? driver;
  final String? platform;
  final String? logPath;
  final ContainerHostConfig? hostConfig;
  final ContainerConfig? config;
  final List<ContainerMount> mounts;
  final ContainerNetworkSettings? networkSettings;

  /// True when `Config.Tty` is set, which decides the log framing of
  /// 03 §5.6.
  bool get tty => config?.tty ?? false;

  static ContainerInspect parse(JsonReader r) {
    final state = r.map('State');
    final hostConfig = r.map('HostConfig');
    final config = r.map('Config');
    final netSettings = r.map('NetworkSettings');
    final name = r.string('Name');
    return ContainerInspect(
      id: r.string('Id') ?? '',
      name: name == null
          ? null
          : (name.startsWith('/') ? name.substring(1) : name),
      created: dateTimeFromString(r.string('Created')),
      path: r.string('Path'),
      args: r.stringList('Args'),
      image: r.string('Image'),
      state: state == null
          ? null
          : ContainerState.parse(JsonReader(state, r.warnings)),
      restartCount: r.integer('RestartCount'),
      driver: r.string('Driver'),
      platform: r.string('Platform'),
      logPath: r.string('LogPath'),
      hostConfig: hostConfig == null
          ? null
          : ContainerHostConfig.parse(JsonReader(hostConfig, r.warnings)),
      config: config == null
          ? null
          : ContainerConfig.parse(JsonReader(config, r.warnings)),
      mounts: [
        for (final e in r.list('Mounts') ?? const <Object?>[])
          if (e is Map)
            ContainerMount.parse(JsonReader(asStringMap(e), r.warnings)),
      ],
      networkSettings: netSettings == null
          ? null
          : ContainerNetworkSettings.parse(JsonReader(netSettings, r.warnings)),
    );
  }
}

/// Parses one `GET /containers/{id}/json` document; never throws.
DockerParseResult<ContainerInspect> parseContainerInspect(Object? decoded) {
  if (decoded is! Map) {
    return const DockerParseResult(ContainerInspect(id: ''), [
      'container inspect is not a JSON object',
    ]);
  }
  final r = JsonReader(asStringMap(decoded));
  return DockerParseResult(ContainerInspect.parse(r), r.warnings);
}
