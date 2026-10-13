import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';

/// Engine information from `GET /info` (03 §7.12 DKE-01): versions,
/// storage, cgroup and logging drivers, rootless flag and warnings. The
/// raw object is kept because none of its fields carry secrets.
@immutable
final class EngineInfo {
  const EngineInfo({
    this.id,
    this.name,
    this.serverVersion,
    this.driver,
    this.driverStatus = const [],
    this.plugins = const {},
    this.loggingDriver,
    this.cgroupDriver,
    this.cgroupVersion,
    this.kernelVersion,
    this.operatingSystem,
    this.osVersion,
    this.osType,
    this.architecture,
    this.dockerRootDir,
    this.containers,
    this.containersRunning,
    this.containersPaused,
    this.containersStopped,
    this.images,
    this.nEventsListener,
    this.nCpu,
    this.memTotal,
    this.securityOptions = const [],
    this.warnings = const [],
    this.swarm,
    this.raw = const {},
  });

  final String? id;
  final String? name;
  final String? serverVersion;
  final String? driver;

  /// `DriverStatus` as `[key, value]` pairs.
  final List<List<String>> driverStatus;

  /// `Plugins` keyed by kind (Volume, Network, Log, ...).
  final Map<String, List<String>> plugins;
  final String? loggingDriver;
  final String? cgroupDriver;
  final String? cgroupVersion;
  final String? kernelVersion;
  final String? operatingSystem;
  final String? osVersion;
  final String? osType;
  final String? architecture;
  final String? dockerRootDir;
  final int? containers;
  final int? containersRunning;
  final int? containersPaused;
  final int? containersStopped;
  final int? images;
  final int? nEventsListener;
  final int? nCpu;
  final int? memTotal;
  final List<String> securityOptions;
  final List<String> warnings;
  final Map<String, Object?>? swarm;

  /// The decoded `/info` object, for fields this model does not name.
  final Map<String, Object?> raw;

  /// Rootless detection (03 §7.12 DKE-01): `SecurityOptions` carries
  /// `name=rootless`.
  bool get rootless => securityOptions.any(
    (o) => o.toLowerCase().replaceAll(' ', '') == 'name=rootless',
  );

  static EngineInfo parse(JsonReader r) {
    final plugins = <String, List<String>>{};
    final pluginMap = r.map('Plugins');
    if (pluginMap != null) {
      final pr = JsonReader(pluginMap, r.warnings);
      for (final key in pluginMap.keys) {
        plugins[key] = pr.stringList(key);
      }
    }
    final driverStatus = <List<String>>[];
    for (final e in r.list('DriverStatus') ?? const <Object?>[]) {
      if (e is List) {
        driverStatus.add([
          for (final v in e)
            if (v is String) v,
        ]);
      } else {
        r.warnings.add('DriverStatus entry is not a list');
      }
    }
    return EngineInfo(
      id: r.string('ID'),
      name: r.string('Name'),
      serverVersion: r.string('ServerVersion'),
      driver: r.string('Driver'),
      driverStatus: driverStatus,
      plugins: plugins,
      loggingDriver: r.string('LoggingDriver'),
      cgroupDriver: r.string('CgroupDriver'),
      cgroupVersion: r.string('CgroupVersion'),
      kernelVersion: r.string('KernelVersion'),
      operatingSystem: r.string('OperatingSystem'),
      osVersion: r.string('OSVersion'),
      osType: r.string('OSType'),
      architecture: r.string('Architecture'),
      dockerRootDir: r.string('DockerRootDir'),
      containers: r.integer('Containers'),
      containersRunning: r.integer('ContainersRunning'),
      containersPaused: r.integer('ContainersPaused'),
      containersStopped: r.integer('ContainersStopped'),
      images: r.integer('Images'),
      nEventsListener: r.integer('NEventsListener'),
      nCpu: r.integer('NCPU'),
      memTotal: r.integer('MemTotal'),
      securityOptions: r.stringList('SecurityOptions'),
      warnings: r.stringList('Warnings'),
      swarm: r.map('Swarm'),
      raw: r.raw,
    );
  }
}

/// Parses a `GET /info` document (03 §7.12 DKE-01); never throws.
DockerParseResult<EngineInfo> parseEngineInfo(Object? decoded) {
  if (decoded is! Map) {
    return const DockerParseResult(EngineInfo(), [
      '/info is not a JSON object',
    ]);
  }
  final r = JsonReader(asStringMap(decoded));
  return DockerParseResult(EngineInfo.parse(r), r.warnings);
}
