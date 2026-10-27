import 'package:meta/meta.dart';

import 'errors.dart';
import 'http_types.dart';
import 'docker_parse_result.dart';

/// A comparable `major.minor` Engine API version (03 §5.8). Versions are
/// values, never strings, so gates compare instead of parsing at use
/// sites.
@immutable
final class ApiVersion implements Comparable<ApiVersion> {
  const ApiVersion(this.major, this.minor);

  final int major;
  final int minor;

  /// Parses `1.44` or `v1.44`; returns null on anything else.
  static ApiVersion? tryParse(String? text) {
    if (text == null) return null;
    var t = text.trim();
    if (t.startsWith('v') || t.startsWith('V')) t = t.substring(1);
    final dot = t.indexOf('.');
    if (dot <= 0 || dot == t.length - 1) return null;
    final major = int.tryParse(t.substring(0, dot));
    final minor = int.tryParse(t.substring(dot + 1));
    if (major == null || minor == null || major < 0 || minor < 0) {
      return null;
    }
    return ApiVersion(major, minor);
  }

  @override
  int compareTo(ApiVersion other) =>
      major != other.major ? major - other.major : minor - other.minor;

  bool operator <(ApiVersion o) => compareTo(o) < 0;
  bool operator >(ApiVersion o) => compareTo(o) > 0;
  bool operator <=(ApiVersion o) => compareTo(o) <= 0;
  bool operator >=(ApiVersion o) => compareTo(o) >= 0;

  @override
  bool operator ==(Object other) =>
      other is ApiVersion && major == other.major && minor == other.minor;

  @override
  int get hashCode => Object.hash(major, minor);

  /// The versioned path prefix form: `v1.44` (03 §5.8).
  String get pathSegment => 'v$major.$minor';

  @override
  String toString() => '$major.$minor';
}

/// Newest API version this client was tested against: the newest version
/// in the recorded fixture corpus (03 §5.8, D21).
const ApiVersion clientMaxTestedApiVersion = ApiVersion(1, 55);

/// Client floor: engines whose maximum is below this are refused
/// (03 §5.8, D21).
const ApiVersion clientApiFloor = ApiVersion(1, 41);

/// From 1.42 the daemon labels log responses with a multiplexed-stream or
/// raw-stream `Content-Type` (03 §5.6).
const ApiVersion apiVersionLogsContentType = ApiVersion(1, 42);

/// `POST /volumes/prune` takes the `all` filter, and without it removes
/// anonymous volumes only, from 1.42 (03 §7.12 DKE-05).
const ApiVersion apiVersionVolumePruneAll = ApiVersion(1, 42);

/// `/images/json` `Containers` count, gated at 1.51 (03 §5.8).
const ApiVersion apiVersionImageContainers = ApiVersion(1, 51);

/// `GET /images/{name}/json?manifests=1` lists an index's children with
/// whether each is present locally (03 §7.14 IMG-05, D68).
const ApiVersion apiVersionImageManifests = ApiVersion(1, 48);

/// Event stream shape: the legacy fields were removed in 1.52 (03 §5.6
/// and §5.8).
const ApiVersion apiVersionEventV2 = ApiVersion(1, 52);

/// `/system/df` shapes, gated at 1.52 and 1.53 (03 §5.8).
const ApiVersion apiVersionSystemDf152 = ApiVersion(1, 52);
const ApiVersion apiVersionSystemDf153 = ApiVersion(1, 53);

/// Build attestations fields, gated at 1.55 (03 §5.8).
const ApiVersion apiVersionAttestations = ApiVersion(1, 55);

/// The `/system/df` response shape for a negotiated version (03 §5.8).
enum SystemDfShape { legacy, v152, v153 }

/// Immutable feature gates derived from the negotiated API version
/// (03 §5.8). Models target 1.44; newer shapes are read through these.
@immutable
final class ApiFeatureGates {
  const ApiFeatureGates(this.negotiated);

  final ApiVersion negotiated;

  /// The daemon labels log responses with the stream Content-Type.
  bool get hasLogsContentType => negotiated >= apiVersionLogsContentType;

  /// `POST /volumes/prune` takes `all`; without it the daemon spares
  /// named volumes.
  bool get hasVolumePruneAll => negotiated >= apiVersionVolumePruneAll;

  /// `/images/json` reports the `Containers` count.
  bool get hasImageContainersCount => negotiated >= apiVersionImageContainers;

  /// An image inspect can list the local index's children.
  bool get hasImageManifests => negotiated >= apiVersionImageManifests;

  /// Events carry the post-1.52 shape (no legacy fields).
  bool get usesEventV2 => negotiated >= apiVersionEventV2;

  /// The `/system/df` shape for the negotiated version.
  SystemDfShape get systemDfShape => negotiated >= apiVersionSystemDf153
      ? SystemDfShape.v153
      : negotiated >= apiVersionSystemDf152
      ? SystemDfShape.v152
      : SystemDfShape.legacy;

  /// Image/build attestation fields exist.
  bool get hasAttestations => negotiated >= apiVersionAttestations;
}

/// What `GET /_ping` (or `HEAD`) reports in its headers (03 §5.8):
/// `Api-Version`, `Libpod-API-Version`, `Docker-Experimental`, `OSType`,
/// `Builder-Version`.
@immutable
final class PingInfo {
  const PingInfo({
    this.apiVersion,
    this.libpodApiVersion,
    this.dockerExperimental,
    this.osType,
    this.builderVersion,
  });

  /// The compat API version the engine offers (`Api-Version`).
  final ApiVersion? apiVersion;

  /// `Libpod-API-Version`: present only on Podman's compat layer.
  final String? libpodApiVersion;

  /// `Docker-Experimental`, parsed as a boolean when it reads true/false.
  final bool? dockerExperimental;

  /// `OSType` (for example `linux`).
  final String? osType;

  /// `Builder-Version`.
  final String? builderVersion;

  /// Podman detection: the compat layer sets `Libpod-API-Version`.
  bool get isPodman => libpodApiVersion != null;
}

/// Parses the `_ping` headers into [PingInfo]; never throws on host input.
DockerParseResult<PingInfo> parsePingHeaders(HttpHeaders headers) {
  final warnings = <String>[];

  final apiVersion = ApiVersion.tryParse(headers.value('Api-Version'));
  if (headers.value('Api-Version') != null && apiVersion == null) {
    warnings.add(
      'unparseable Api-Version header ${headers.value('Api-Version')}',
    );
  }

  bool? experimental;
  final expRaw = headers.value('Docker-Experimental');
  if (expRaw != null) {
    experimental = switch (expRaw.trim().toLowerCase()) {
      'true' => true,
      'false' => false,
      _ => () {
        warnings.add('unparseable Docker-Experimental header $expRaw');
        return null;
      }(),
    };
  }

  return DockerParseResult(
    PingInfo(
      apiVersion: apiVersion,
      libpodApiVersion: headers.value('Libpod-API-Version'),
      dockerExperimental: experimental,
      osType: headers.value('OSType'),
      builderVersion: headers.value('Builder-Version'),
    ),
    warnings,
  );
}

/// One `Components[]` entry of `GET /version` (03 §7.12 DKE-01).
@immutable
final class EngineComponent {
  const EngineComponent({this.name, this.version, this.details = const {}});

  final String? name;
  final String? version;
  final Map<String, Object?> details;
}

/// The fields of `GET /version` the negotiation and engine panels use
/// (03 §5.8, §7.12). Models are tolerant: unknown fields are ignored.
@immutable
final class DockerServerVersion {
  const DockerServerVersion({
    this.apiVersion,
    this.minApiVersion,
    this.version,
    this.gitCommit,
    this.goVersion,
    this.os,
    this.arch,
    this.kernelVersion,
    this.experimental,
    this.isPodman = false,
    this.platformName,
    this.components = const [],
  });

  /// `ApiVersion`: the newest compat version the engine offers.
  final ApiVersion? apiVersion;

  /// `MinAPIVersion`: the oldest compat version the engine accepts.
  final ApiVersion? minApiVersion;

  /// Engine version string (`Version`, for example `29.0.1`).
  final String? version;
  final String? gitCommit;
  final String? goVersion;
  final String? os;
  final String? arch;
  final String? kernelVersion;
  final bool? experimental;

  /// Podman detection through `/version` (`Components[].Name` or
  /// `Platform.Name` mentions Podman).
  final bool isPodman;

  /// `Platform.Name` (for example `Docker Engine - Community`).
  final String? platformName;

  /// `Components[]` (Engine, containerd, runc, ...) for the engine panel.
  final List<EngineComponent> components;
}

/// Parses a decoded `GET /version` JSON document; never throws on host
/// input.
DockerParseResult<DockerServerVersion> parseServerVersion(Object? decoded) {
  final warnings = <String>[];
  if (decoded is! Map<String, Object?>) {
    warnings.add('/version document is not a JSON object');
    return DockerParseResult(const DockerServerVersion(), warnings);
  }

  ApiVersion? versionField(String key) {
    final raw = decoded[key];
    if (raw == null) return null;
    if (raw is! String) {
      warnings.add('$key is not a string');
      return null;
    }
    final parsed = ApiVersion.tryParse(raw);
    if (parsed == null) warnings.add('unparseable $key $raw');
    return parsed;
  }

  String? stringField(String key) {
    final raw = decoded[key];
    if (raw == null) return null;
    if (raw is! String) {
      warnings.add('$key is not a string');
      return null;
    }
    return raw;
  }

  bool? boolField(String key) {
    final raw = decoded[key];
    if (raw == null) return null;
    if (raw is! bool) {
      warnings.add('$key is not a bool');
      return null;
    }
    return raw;
  }

  // Podman marks itself in Components[].Name or Platform.Name.
  var podman = false;
  final components = <EngineComponent>[];
  final rawComponents = decoded['Components'];
  if (rawComponents is List) {
    for (final c in rawComponents) {
      if (c is Map) {
        final name = c['Name'];
        final version = c['Version'];
        final details = c['Details'];
        components.add(
          EngineComponent(
            name: name is String ? name : null,
            version: version is String ? version : null,
            details: details is Map
                ? {
                    for (final e in details.entries)
                      if (e.key is String) e.key as String: e.value,
                  }
                : const {},
          ),
        );
        if (name is String && name.toLowerCase().contains('podman')) {
          podman = true;
        }
      }
    }
  }
  String? platformName;
  final platform = decoded['Platform'];
  if (platform is Map) {
    final name = platform['Name'];
    if (name is String) {
      platformName = name;
      if (name.toLowerCase().contains('podman')) podman = true;
    }
  }

  return DockerParseResult(
    DockerServerVersion(
      apiVersion: versionField('ApiVersion'),
      minApiVersion: versionField('MinAPIVersion'),
      version: stringField('Version'),
      gitCommit: stringField('GitCommit'),
      goVersion: stringField('GoVersion'),
      os: stringField('Os'),
      arch: stringField('Arch'),
      kernelVersion: stringField('KernelVersion'),
      experimental: boolField('Experimental'),
      isPodman: podman,
      platformName: platformName,
      components: components,
    ),
    warnings,
  );
}

/// The negotiated outcome for one engine (03 §5.8): the version used in
/// versioned paths plus the immutable gates the models read.
@immutable
final class DockerNegotiation {
  const DockerNegotiation({
    required this.negotiated,
    required this.isPodman,
    this.serverMax,
    this.serverMin,
  });

  /// `min(clientMaxTested, serverMax)`, already validated against the
  /// server minimum and the client floor.
  final ApiVersion negotiated;

  /// True when the engine is Podman's compat layer.
  final bool isPodman;

  /// The engine's reported maximum, when known.
  final ApiVersion? serverMax;

  /// The engine's reported `MinAPIVersion`, when known.
  final ApiVersion? serverMin;

  /// Feature gates derived from [negotiated].
  ApiFeatureGates get gates => ApiFeatureGates(negotiated);
}

/// Pure negotiation (03 §5.8, D21): `negotiated = min(clientMax,
/// serverMax)`, refused below the server minimum or the client floor.
/// Throws [NegotiationRefusedException] on refusal.
DockerNegotiation negotiateApiVersion({
  required ApiVersion? serverMax,
  ApiVersion? serverMin,
  bool isPodman = false,
  ApiVersion clientMax = clientMaxTestedApiVersion,
  ApiVersion floor = clientApiFloor,
}) {
  if (serverMax == null) {
    throw NegotiationRefusedException(NegotiationRefusal.serverVersionUnknown);
  }
  final negotiated = serverMax < clientMax ? serverMax : clientMax;
  if (negotiated < floor) {
    throw NegotiationRefusedException(
      NegotiationRefusal.belowClientFloor,
      serverMax: serverMax,
      serverMin: serverMin,
      negotiated: negotiated,
    );
  }
  if (serverMin != null && negotiated < serverMin) {
    throw NegotiationRefusedException(
      NegotiationRefusal.belowServerMinimum,
      serverMax: serverMax,
      serverMin: serverMin,
      negotiated: negotiated,
    );
  }
  return DockerNegotiation(
    negotiated: negotiated,
    isPodman: isPodman,
    serverMax: serverMax,
    serverMin: serverMin,
  );
}
