import 'dart:convert';

import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';
import '../masking.dart';

/// One published port from `docker compose ps --format json`.
@immutable
final class ComposePublisher {
  const ComposePublisher({
    this.url,
    this.targetPort,
    this.publishedPort,
    this.protocol,
  });

  final String? url;
  final int? targetPort;
  final int? publishedPort;
  final String? protocol;

  static ComposePublisher parse(JsonReader r) => ComposePublisher(
    url: r.string('URL'),
    targetPort: r.integer('TargetPort'),
    publishedPort: r.integer('PublishedPort'),
    protocol: r.string('Protocol'),
  );
}

/// One `docker compose ps --format json` entry (03 §7.16 STK-02).
@immutable
final class ComposePsEntry {
  const ComposePsEntry({
    required this.id,
    this.name,
    this.image,
    this.command,
    this.project,
    this.service,
    this.state,
    this.health,
    this.exitCode,
    this.publishers = const [],
    this.createdAt,
    this.startedAt,
    this.labels = const {},
  });

  final String id;
  final String? name;
  final String? image;
  final String? command;
  final String? project;
  final String? service;
  final String? state;
  final String? health;
  final int? exitCode;
  final List<ComposePublisher> publishers;
  final String? createdAt;
  final String? startedAt;
  final Map<String, MaskedValue> labels;

  static ComposePsEntry parse(JsonReader r) => ComposePsEntry(
    id: r.string('ID') ?? r.string('Id') ?? '',
    name: r.string('Name'),
    image: r.string('Image'),
    command: r.string('Command'),
    project: r.string('Project'),
    service: r.string('Service'),
    state: r.string('State'),
    health: r.string('Health'),
    exitCode: r.integer('ExitCode'),
    publishers: [
      for (final e in r.list('Publishers') ?? const <Object?>[])
        if (e is Map)
          ComposePublisher.parse(JsonReader(asStringMap(e), r.warnings)),
    ],
    createdAt: r.string('CreatedAt'),
    startedAt: r.string('StartedAt'),
    labels: maskedLabels(r.stringMap('Labels')),
  );
}

/// Parses `docker compose ps --format json`, which is an NDJSON stream on
/// Compose v2 and a JSON array on some versions (03 §7.16 STK-02). Never
/// throws.
DockerParseResult<List<ComposePsEntry>> parseComposePsJson(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return const DockerParseResult(<ComposePsEntry>[]);
  }
  if (trimmed.startsWith('[')) {
    try {
      return parseComposePsEntries(jsonDecode(trimmed));
    } catch (e) {
      return DockerParseResult(const <ComposePsEntry>[], [
        'compose ps is not valid JSON: $e',
      ]);
    }
  }
  final warnings = <String>[];
  final out = <ComposePsEntry>[];
  for (final line in const LineSplitter().convert(text)) {
    final l = line.trim();
    if (l.isEmpty) continue;
    try {
      final decoded = jsonDecode(l);
      if (decoded is Map) {
        out.add(
          ComposePsEntry.parse(JsonReader(asStringMap(decoded), warnings)),
        );
      } else {
        warnings.add('compose ps line is not a JSON object');
      }
    } catch (e) {
      warnings.add('compose ps line is not valid JSON: $e');
    }
  }
  return DockerParseResult(out, warnings);
}

/// Parses a decoded `docker compose ps` array or object.
DockerParseResult<List<ComposePsEntry>> parseComposePsEntries(Object? decoded) {
  final warnings = <String>[];
  final list = decoded is List ? decoded : <Object?>[decoded];
  final out = <ComposePsEntry>[];
  for (final e in list) {
    if (e is Map) {
      out.add(ComposePsEntry.parse(JsonReader(asStringMap(e), warnings)));
    } else {
      warnings.add('compose ps entry is not an object');
    }
  }
  return DockerParseResult(out, warnings);
}

/// The structural parts of `docker compose config --format json` the app
/// uses (03 §7.16 STK-01, STK-04). Environment and secret values are
/// deliberately not modelled: the interpolated output contains secrets
/// and is never cached or synced (03 §7.16).
@immutable
final class ComposeServiceConfig {
  const ComposeServiceConfig({
    required this.name,
    this.image,
    this.dependsOn = const [],
    this.profiles = const [],
    this.ports = const [],
  });

  final String name;
  final String? image;
  final List<String> dependsOn;
  final List<String> profiles;
  final List<String> ports;
}

/// A parsed `docker compose config --format json` document.
@immutable
final class ComposeConfig {
  const ComposeConfig({
    this.name,
    this.services = const {},
    this.volumes = const [],
    this.networks = const [],
  });

  final String? name;
  final Map<String, ComposeServiceConfig> services;
  final List<String> volumes;
  final List<String> networks;
}

/// Parses a decoded `docker compose config --format json` document;
/// never throws.
DockerParseResult<ComposeConfig> parseComposeConfig(Object? decoded) {
  final warnings = <String>[];
  if (decoded is! Map) {
    warnings.add('compose config is not a JSON object');
    return DockerParseResult(const ComposeConfig(), warnings);
  }
  final r = JsonReader(asStringMap(decoded), warnings);
  final services = <String, ComposeServiceConfig>{};
  final serviceMap = r.map('services');
  if (serviceMap != null) {
    for (final e in serviceMap.entries) {
      final v = e.value;
      if (v is! Map) {
        warnings.add('compose config service ${e.key} is not an object');
        continue;
      }
      final sr = JsonReader(asStringMap(v), warnings);
      final depends = <String>[];
      final dependsRaw = sr['depends_on'];
      if (dependsRaw is Map) {
        depends.addAll(asStringMap(dependsRaw).keys);
      } else if (dependsRaw is List) {
        for (final d in dependsRaw) {
          if (d is String) depends.add(d);
        }
      }
      services[e.key] = ComposeServiceConfig(
        name: e.key,
        image: sr.string('image'),
        dependsOn: depends,
        profiles: sr.stringList('profiles'),
        ports: _portStrings(sr['ports']),
      );
    }
  }
  return DockerParseResult(
    ComposeConfig(
      name: r.string('name'),
      services: services,
      volumes: r.map('volumes')?.keys.toList() ?? const [],
      networks: r.map('networks')?.keys.toList() ?? const [],
    ),
    warnings,
  );
}

/// Each service's config hash from `docker compose config --hash '*'`
/// (03 §7.16 STK-01): one `<service> <hash>` line per service, as
/// `runHash` in Compose's `cmd/compose/config.go` prints them (read on
/// its v5 main branch; a released binary is checked in D21). Null when
/// the output is empty or any line is not that shape, as a CLI that
/// reads `--hash` otherwise would print.
Map<String, String>? parseComposeServiceHashes(String text) {
  final hashes = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    final match = _serviceHashLine.firstMatch(line.trim());
    if (match == null) return null;
    hashes[match[1]!] = match[2]!;
  }
  return hashes.isEmpty ? null : hashes;
}

final _serviceHashLine = RegExp(r'^([a-zA-Z0-9][a-zA-Z0-9._-]*) ([a-f0-9]+)$');

/// `docker compose version --format json` (03 §7.16 STK-05).
@immutable
final class ComposeVersionInfo {
  const ComposeVersionInfo({
    this.version,
    this.revision,
    this.goVersion,
    this.gitCommit,
  });

  final String? version;
  final String? revision;
  final String? goVersion;
  final String? gitCommit;

  static ComposeVersionInfo parse(JsonReader r) => ComposeVersionInfo(
    version: r.string('version') ?? r.string('Version'),
    revision: r.string('revision') ?? r.string('Revision'),
    goVersion: r.string('goVersion') ?? r.string('GoVersion'),
    gitCommit: r.string('gitCommit') ?? r.string('GitCommit'),
  );
}

/// Parses a `docker compose version` document; never throws.
DockerParseResult<ComposeVersionInfo> parseComposeVersion(Object? decoded) {
  if (decoded is! Map) {
    return const DockerParseResult(ComposeVersionInfo(), [
      'compose version is not a JSON object',
    ]);
  }
  final r = JsonReader(asStringMap(decoded));
  return DockerParseResult(ComposeVersionInfo.parse(r), r.warnings);
}

List<String> _portStrings(Object? ports) {
  if (ports is! List) return const [];
  final out = <String>[];
  for (final p in ports) {
    if (p is String) {
      out.add(p);
    } else if (p is Map) {
      final r = JsonReader(asStringMap(p));
      final published = r.integer('published');
      final target = r.integer('target');
      final protocol = r.string('protocol');
      if (published != null && target != null) {
        out.add('$published:$target${protocol == null ? '' : '/$protocol'}');
      }
    }
  }
  return out;
}
