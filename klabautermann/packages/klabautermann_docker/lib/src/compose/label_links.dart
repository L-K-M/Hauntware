import 'package:meta/meta.dart';

import '../masking.dart';

/// Where a [LabelLink] came from (02 CTR-11).
enum LabelLinkSource {
  /// `dockhand.url`, or `dockhand.port.<port>.url` for one port.
  dockhand,

  /// `dev.dozzle.url`.
  dozzle,

  /// A Traefik router's `Host(...)` rule.
  traefik,

  /// A caddy-docker-proxy site address (`caddy`, `caddy_0`, ...).
  caddy,
}

/// A web page a container's labels point at (02 CTR-11): its own UI as
/// another tool links it, or a host a reverse proxy serves it on.
@immutable
final class LabelLink {
  const LabelLink({
    required this.uri,
    required this.source,
    required this.label,
    this.name,
    this.port,
  });

  /// An `http` or `https` address without credentials.
  final Uri uri;

  final LabelLinkSource source;

  /// The label it was read from.
  final String label;

  /// The name a `dockhand.url=[Name](url)` value gives it.
  final String? name;

  /// The container port a `dockhand.port.<port>.url` label names.
  final int? port;

  @override
  bool operator ==(Object other) =>
      other is LabelLink && other.uri == uri && other.source == source;

  @override
  int get hashCode => Object.hash(uri, source);
}

const _dockhandUrl = 'dockhand.url';
final _dockhandPortUrl = RegExp(r'^dockhand\.port\.(\d{1,5})\.url$');
const _dozzleUrl = 'dev.dozzle.url';
final _traefikRule = RegExp(r'^traefik\.http\.routers\.([^.]+)\.rule$');
const _traefikEnable = 'traefik.enable';
final _caddySite = RegExp(r'^caddy(_\d+)?$');

/// `[Name](https://...)`, Dockhand's named link.
final _markdownLink = RegExp(r'^\[([^\]]+)\]\((\S+)\)$');

/// The hosts of a Traefik rule's `Host(...)` matchers: each takes one or
/// more quoted names, in backquotes or double quotes.
final _traefikHost = RegExp(r'Host\(([^)]*)\)');
final _quoted = RegExp(r'[`"]([^`"]+)[`"]');

/// A host name a link can carry: letters, digits, dots and hyphens, as a
/// proxy rule names one (no wildcard or placeholder).
final _hostName = RegExp(
  r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$',
);

/// The links [labels] name (02 CTR-11), in label order, each address
/// once: Dockhand's and Dozzle's URL labels, Traefik routers' `Host`
/// rules and caddy-docker-proxy site addresses. A masked value, an
/// address that is not `http` or `https`, and one with credentials name
/// none, nor does a Traefik rule while `traefik.enable` is `false`.
List<LabelLink> labelLinks(Map<String, MaskedValue> labels) {
  final links = <LabelLink>[];
  void add(LabelLink? link) {
    if (link != null && !links.contains(link)) links.add(link);
  }

  final traefikOn = switch (labels[_traefikEnable]) {
    final value? when !value.isMasked =>
      value.display.trim().toLowerCase() != 'false',
    _ => true,
  };
  for (final MapEntry(:key, :value) in labels.entries) {
    if (value.isMasked) continue;
    final text = value.display.trim();
    if (key == _dockhandUrl) {
      add(_dockhand(key, text));
    } else if (_dockhandPortUrl.firstMatch(key) case final match?) {
      final port = int.parse(match[1]!);
      if (port > 0 && port <= 65535) add(_dockhand(key, text, port: port));
    } else if (key == _dozzleUrl) {
      if (_webUri(text) case final uri?) {
        add(LabelLink(uri: uri, source: LabelLinkSource.dozzle, label: key));
      }
    } else if (_traefikRule.firstMatch(key) case final match? when traefikOn) {
      final router = match[1]!;
      final scheme = _traefikSecure(labels, router) ? 'https' : 'http';
      for (final host in _traefikHosts(text)) {
        add(
          LabelLink(
            uri: Uri(scheme: scheme, host: host),
            source: LabelLinkSource.traefik,
            label: key,
          ),
        );
      }
    } else if (_caddySite.hasMatch(key)) {
      for (final uri in _caddySites(text)) {
        add(LabelLink(uri: uri, source: LabelLinkSource.caddy, label: key));
      }
    }
  }
  return links;
}

LabelLink? _dockhand(String key, String text, {int? port}) {
  final named = _markdownLink.firstMatch(text);
  final uri = _webUri(named?[2] ?? text);
  if (uri == null) return null;
  return LabelLink(
    uri: uri,
    source: LabelLinkSource.dockhand,
    label: key,
    // A blank name would hide the address behind an empty title.
    name: switch (named?[1]?.trim()) {
      final name? when name.isNotEmpty => name,
      _ => null,
    },
    port: port,
  );
}

/// [text] as an absolute `http` or `https` address with a host and no
/// credentials, or null.
Uri? _webUri(String text) {
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.userInfo.isNotEmpty) return null;
  return uri;
}

/// Whether [router] serves TLS: its `tls` label, a certificate resolver,
/// or an entry point named for HTTPS.
bool _traefikSecure(Map<String, MaskedValue> labels, String router) {
  String? read(String suffix) {
    final value = labels['traefik.http.routers.$router.$suffix'];
    return value == null || value.isMasked ? null : value.display.trim();
  }

  if (read('tls')?.toLowerCase() == 'true') return true;
  if (read('tls.certresolver')?.isNotEmpty ?? false) return true;
  final entryPoints = {
    for (final name in (read('entrypoints') ?? '').split(','))
      name.trim().toLowerCase(),
  };
  return entryPoints.contains('websecure') || entryPoints.contains('https');
}

Iterable<String> _traefikHosts(String rule) sync* {
  for (final matcher in _traefikHost.allMatches(rule)) {
    for (final quoted in _quoted.allMatches(matcher[1]!)) {
      final host = quoted[1]!.trim().toLowerCase();
      if (_hostName.hasMatch(host)) yield host;
    }
  }
}

/// caddy-docker-proxy's site addresses: comma- or space-separated, each
/// a host with an optional port (served over HTTPS, as Caddy does by
/// default, but over HTTP on port 80) or a URL; wildcards, placeholders and paths beyond a URL's
/// own are skipped.
Iterable<Uri> _caddySites(String value) sync* {
  for (final address in value.split(RegExp(r'[,\s]+'))) {
    if (address.isEmpty) continue;
    if (address.contains('://')) {
      if (_webUri(address) case final uri?) yield uri;
      continue;
    }
    final [host, ...rest] = address.split(':');
    final port = rest.length == 1 ? int.tryParse(rest.single) : null;
    if (!_hostName.hasMatch(host)) continue;
    if (rest.isNotEmpty && (port == null || port < 1 || port > 65535)) {
      continue;
    }
    // Caddy serves an explicit port 80 over plain HTTP, any other over
    // HTTPS.
    yield Uri(
      scheme: port == 80 ? 'http' : 'https',
      host: host.toLowerCase(),
      port: port,
    );
  }
}
