import 'dart:convert' show JsonEncoder;

import 'package:klabautermann_core/klabautermann_core.dart'
    show
        ContainerDetails,
        ContainerHostConfig,
        ContainerMount,
        ContainerNetworkSettings,
        MaskedValue;

/// The restart policies the Engine API names (`HostConfig.RestartPolicy`),
/// which the details name in words.
enum RestartPolicyKind {
  no,
  always,
  unlessStopped,
  onFailure;

  /// [name] as the engine gave it: an empty name is the default, `no`.
  /// Null for a name outside the API's list, which the details show as
  /// the engine gave it.
  static RestartPolicyKind? of(String? name) => switch (name) {
    null || '' || 'no' => no,
    'always' => always,
    'unless-stopped' => unlessStopped,
    'on-failure' => onFailure,
    _ => null,
  };
}

/// [time] unless it is the Engine API's zero time (`0001-01-01T00:00:00Z`),
/// which `StartedAt` and `FinishedAt` read before a container ran.
DateTime? engineTime(DateTime? time) {
  if (time == null || time.year <= 1) return null;
  return time;
}

/// [container] as the details' raw view shows it: the inspect fields the
/// engine sent, under the Engine API's names, as indented JSON. It is
/// rendered from the masked model (03 §8.9), each masked value as its
/// display text, so it never holds a secret, whatever the details reveal.
/// A logging driver's options are left out: the model carries them
/// unmasked, and a driver option can be a token (`splunk-token`).
String containerDetailsJson(ContainerDetails container) {
  final state = container.state;
  final health = state?.health;
  final config = container.config;
  final document = <String, Object?>{
    'Id': container.id,
    'Name': ?container.name,
    'Created': ?_timeJson(container.created),
    'Image': ?container.image,
    'Platform': ?container.platform,
    'RestartCount': ?container.restartCount,
    'Path': ?container.path,
    'Args': _masked(container.args),
    if (state != null)
      'State': {
        'Status': ?state.status,
        'Running': state.running,
        'Paused': state.paused,
        'Restarting': state.restarting,
        'OOMKilled': state.oomKilled,
        'Dead': state.dead,
        'Pid': ?state.pid,
        'ExitCode': ?state.exitCode,
        'Error': ?state.error,
        'StartedAt': ?_timeJson(state.startedAt),
        'FinishedAt': ?_timeJson(state.finishedAt),
        if (health != null)
          'Health': {
            'Status': health.status.name,
            'FailingStreak': ?health.failingStreak,
            'Log': [
              for (final check in health.log)
                {
                  'Start': ?_timeJson(check.start),
                  'End': ?_timeJson(check.end),
                  'ExitCode': ?check.exitCode,
                  'Output': ?check.output?.display,
                },
            ],
          },
      },
    if (config != null)
      'Config': {
        'Hostname': ?config.hostname,
        'User': ?config.user,
        'Env': [
          for (final variable in config.env)
            '${variable.name}=${variable.value.display}',
        ],
        'Cmd': _masked(config.cmd),
        'Image': ?config.image,
        'WorkingDir': ?config.workingDir,
        'Entrypoint': _masked(config.entrypoint),
        'Labels': {
          for (final MapEntry(:key, :value) in config.labels.entries)
            key: value.display,
        },
        'StopSignal': ?config.stopSignal,
        'Tty': config.tty,
      },
    if (container.hostConfig case final hostConfig?)
      'HostConfig': _hostConfigJson(hostConfig),
    'Mounts': [for (final mount in container.mounts) _mountJson(mount)],
    if (container.networkSettings case final settings?)
      'NetworkSettings': _networkSettingsJson(settings),
  };
  return const JsonEncoder.withIndent('  ').convert(document);
}

List<String> _masked(List<MaskedValue> values) => [
  for (final value in values) value.display,
];

/// A time as the Engine API writes it, in UTC; none for its zero time.
String? _timeJson(DateTime? time) =>
    engineTime(time)?.toUtc().toIso8601String();

Map<String, Object?> _hostConfigJson(ContainerHostConfig hostConfig) {
  final restart = hostConfig.restartPolicy;
  final log = hostConfig.logConfig;
  return {
    'Binds': hostConfig.binds,
    'NetworkMode': ?hostConfig.networkMode,
    if (restart != null)
      'RestartPolicy': {
        'Name': restart.name ?? '',
        'MaximumRetryCount': ?restart.maximumRetryCount,
      },
    'AutoRemove': hostConfig.autoRemove,
    if (log != null) 'LogConfig': {'Type': ?log.type},
    'Privileged': hostConfig.privileged,
    'ReadonlyRootfs': hostConfig.readonlyRootfs,
    'PidMode': ?hostConfig.pidMode,
    'Memory': ?hostConfig.memory,
    'NanoCpus': ?hostConfig.nanoCpus,
  };
}

Map<String, Object?> _mountJson(ContainerMount mount) => {
  'Type': ?mount.type,
  'Name': ?mount.name,
  'Source': ?mount.source,
  'Destination': ?mount.destination,
  'Driver': ?mount.driver,
  'Mode': ?mount.mode,
  'RW': ?mount.rw,
  'Propagation': ?mount.propagation,
};

Map<String, Object?> _networkSettingsJson(ContainerNetworkSettings settings) =>
    {
      'IPAddress': ?settings.ipAddress,
      'Gateway': ?settings.gateway,
      'Networks': {
        for (final MapEntry(:key, :value) in settings.networks.entries)
          key: {
            'Aliases': value.aliases,
            'NetworkID': ?value.networkId,
            'Gateway': ?value.gateway,
            'IPAddress': ?value.ipAddress,
            'MacAddress': ?value.macAddress,
          },
      },
    };
