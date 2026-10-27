import 'package:meta/meta.dart';

import 'http_types.dart';

/// Docker Hub's registry API host; `docker.io` names it in references.
const String dockerHubRegistry = 'registry-1.docker.io';

const String _dockerHubDomain = 'docker.io';
const String _officialNamespace = 'library/';
const String _defaultTag = 'latest';

final _pathComponent = RegExp(r'^[a-z0-9]+(?:(?:\.|_|__|-+)[a-z0-9]+)*$');
final _tag = RegExp(r'^\w[\w.-]{0,127}$');
final _digest = RegExp(r'^sha256:[a-f0-9]{64}$');
final _domain = RegExp(r'^[a-zA-Z0-9.-]+(?::[0-9]+)?$');

/// An image reference split the way an update check needs it (03 §7.14
/// IMG-05, D68): the registry host the `HEAD` goes to, the repository
/// path in the registry's API, the tag, and the name `RepoDigests` uses
/// for it.
@immutable
final class RegistryReference {
  const RegistryReference._({
    required this.registry,
    required this.repository,
    required this.tag,
    required this.familiarName,
    this.digest,
  });

  /// The registry host, with its port when the reference names one;
  /// Docker Hub references use [dockerHubRegistry].
  final String registry;

  /// The repository path in the registry API, e.g. `library/alpine`.
  final String repository;

  /// The tag, `latest` when the reference names none.
  final String tag;

  /// The repository as `RepoDigests` and `RepoTags` write it: Docker Hub
  /// references drop `docker.io/` and `library/`, e.g. `alpine`,
  /// `grafana/grafana`, `ghcr.io/home-assistant/home-assistant`.
  final String familiarName;

  /// The digest a `name@sha256:...` reference pins, or null.
  final String? digest;

  /// Whether the reference pins a digest; such an image never updates
  /// under its own name, so no check runs for it.
  bool get isPinned => digest != null;

  bool get isDockerHub => registry == dockerHubRegistry;

  /// Splits [reference] as Docker normalizes it; null when it is not a
  /// valid image reference.
  static RegistryReference? tryParse(String reference) {
    var rest = reference.trim();
    String? digest;
    final at = rest.indexOf('@');
    if (at >= 0) {
      digest = rest.substring(at + 1);
      rest = rest.substring(0, at);
      if (!_digest.hasMatch(digest)) return null;
    }

    var tag = _defaultTag;
    final lastColon = rest.lastIndexOf(':');
    if (lastColon > rest.lastIndexOf('/')) {
      tag = rest.substring(lastColon + 1);
      rest = rest.substring(0, lastColon);
      if (!_tag.hasMatch(tag)) return null;
    }

    var domain = _dockerHubDomain;
    final slash = rest.indexOf('/');
    if (slash > 0) {
      final first = rest.substring(0, slash);
      // Docker reads the first component as a host when it has a dot, a
      // port or is `localhost`.
      if (first.contains('.') || first.contains(':') || first == 'localhost') {
        if (!_domain.hasMatch(first)) return null;
        domain = first;
        rest = rest.substring(slash + 1);
      }
    }
    if (rest.isEmpty || !rest.split('/').every(_pathComponent.hasMatch)) {
      return null;
    }

    if (domain == _dockerHubDomain || domain == 'index.docker.io') {
      final repository = rest.contains('/') ? rest : '$_officialNamespace$rest';
      final familiar = repository.startsWith(_officialNamespace)
          ? repository.substring(_officialNamespace.length)
          : repository;
      return RegistryReference._(
        registry: dockerHubRegistry,
        repository: repository,
        tag: tag,
        familiarName: familiar,
        digest: digest,
      );
    }
    return RegistryReference._(
      registry: domain,
      repository: rest,
      tag: tag,
      familiarName: '$domain/$rest',
      digest: digest,
    );
  }
}

/// How a registry asks for authentication (`WWW-Authenticate`).
enum RegistryAuthScheme { bearer, basic, other }

/// A registry's `WWW-Authenticate` challenge (D68): a `Bearer` challenge
/// names the realm that hands out anonymous pull tokens; a `Basic` one
/// means the registry needs credentials, which the device does not hold.
@immutable
final class RegistryChallenge {
  const RegistryChallenge({
    required this.scheme,
    this.realm,
    this.service,
    this.scope,
  });

  final RegistryAuthScheme scheme;
  final String? realm;
  final String? service;
  final String? scope;

  static final _parameter = RegExp(r'([A-Za-z]+)="([^"]*)"');

  /// Parses one challenge; null for an empty header.
  static RegistryChallenge? tryParse(String? header) {
    final text = header?.trim() ?? '';
    if (text.isEmpty) return null;
    final space = text.indexOf(' ');
    final schemeName = (space < 0 ? text : text.substring(0, space))
        .toLowerCase();
    final scheme = switch (schemeName) {
      'bearer' => RegistryAuthScheme.bearer,
      'basic' => RegistryAuthScheme.basic,
      _ => RegistryAuthScheme.other,
    };
    final parameters = {
      for (final m in _parameter.allMatches(text))
        m.group(1)!.toLowerCase(): m.group(2)!,
    };
    return RegistryChallenge(
      scheme: scheme,
      realm: parameters['realm'],
      service: parameters['service'],
      scope: parameters['scope'],
    );
  }

  /// The anonymous pull-token request for [repository], or null when the
  /// challenge is not `Bearer` or its realm is not an `https` URL. The
  /// request carries no credentials, but a realm the registry names is
  /// still only followed over TLS.
  Uri? anonymousTokenUri(String repository) {
    if (scheme != RegistryAuthScheme.bearer) return null;
    final base = Uri.tryParse(realm ?? '');
    if (base == null || base.scheme != 'https' || base.host.isEmpty) {
      return null;
    }
    return base.replace(
      queryParameters: {
        ...base.queryParameters,
        'service': ?service,
        'scope': 'repository:$repository:pull',
      },
    );
  }
}

/// Docker Hub's `ratelimit-limit` and `ratelimit-remaining` headers
/// (`100;w=3600`): requests left for the source address in a window
/// (D68: one hour in 2026, read rather than assumed).
@immutable
final class RegistryRateLimit {
  const RegistryRateLimit({this.limit, this.remaining, this.window});

  final int? limit;
  final int? remaining;
  final Duration? window;

  bool get isSpent => remaining == 0;

  /// Reads the headers; null when the registry sends neither.
  static RegistryRateLimit? fromHeaders(HttpHeaders headers) {
    final limit = _parse(headers.value('ratelimit-limit'));
    final remaining = _parse(headers.value('ratelimit-remaining'));
    if (limit == null && remaining == null) return null;
    return RegistryRateLimit(
      limit: limit?.count,
      remaining: remaining?.count,
      window: remaining?.window ?? limit?.window,
    );
  }

  static ({int? count, Duration? window})? _parse(String? value) {
    if (value == null) return null;
    final parts = value.split(';');
    final count = int.tryParse(parts.first.trim());
    Duration? window;
    for (final part in parts.skip(1)) {
      final kv = part.trim();
      if (!kv.startsWith('w=')) continue;
      final seconds = int.tryParse(kv.substring(2));
      if (seconds != null && seconds > 0) window = Duration(seconds: seconds);
    }
    if (count == null && window == null) return null;
    return (count: count, window: window);
  }
}
