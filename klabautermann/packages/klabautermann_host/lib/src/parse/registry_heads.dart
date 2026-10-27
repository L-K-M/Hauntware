/// Parser for IMG-05's registry read (03 §7.14, D68): one manifest `HEAD`
/// per image, sent by `curl` on the host after the registry's anonymous
/// token flow, and `docker buildx imagetools inspect` where the registry
/// wants credentials, as [HostCommands.registryHeads] prints them.
library;

import 'package:meta/meta.dart';

/// The line [HostCommands.registryHeads] prints when the host has no
/// `curl`; nothing else follows it.
const kRegistryNoCurlMarker = '== no curl';

/// The line before each image's part: `== image <reference>`.
const kRegistryImageMarker = '== image';

/// The line before the `HEAD`'s response headers: `== head <curl exit>`.
const kRegistryHeadMarker = '== head';

/// The line before buildx's JSON: `== cli <exit>`, or `== cli missing`
/// when the host has no buildx plugin.
const kRegistryCliMarker = '== cli';

/// How many images one read checks; more go in later reads.
const kRegistryHeadsMax = 64;

/// The bytes of buildx output kept for one image.
const kRegistryCliMaxBytes = 65536;

/// One image to check: where its `HEAD` goes and the reference the host
/// CLI resolves. The engine builds these from validated references.
@immutable
final class RegistryHeadTarget {
  const RegistryHeadTarget({
    required this.registry,
    required this.repository,
    required this.tag,
    required this.reference,
  });

  /// The registry host, with its port when there is one.
  final String registry;

  /// The repository path in the registry API, e.g. `library/alpine`.
  final String repository;
  final String tag;

  /// The reference as the image was pulled, e.g. `alpine:3.22`.
  final String reference;
}

/// What one image's part of the read says.
@immutable
final class RegistryHeadRead {
  const RegistryHeadRead({
    required this.reference,
    this.curlExit,
    this.statusCode,
    this.headers = const [],
    this.cliExit,
    this.cliMissing = false,
    this.cliOutput,
  });

  final String reference;

  /// `curl`'s exit status for the `HEAD`; 0 when it got an answer.
  final int? curlExit;

  /// The status of the last HTTP response, after any proxy's
  /// `Connection Established`.
  final int? statusCode;

  /// The response headers the read keeps, lower-cased names in order:
  /// `docker-content-digest`, `content-type`, `ratelimit-*` and
  /// `www-authenticate`.
  final List<(String, String)> headers;

  /// buildx's exit status, when the registry wanted credentials and the
  /// host has the plugin.
  final int? cliExit;

  /// The registry wanted credentials and the host has no buildx plugin.
  final bool cliMissing;

  /// buildx's output: the manifest JSON, or its error text.
  final String? cliOutput;

  /// The first value of header [name] (lower case), or null.
  String? header(String name) {
    for (final (key, value) in headers) {
      if (key == name) return value;
    }
    return null;
  }
}

/// The whole read.
@immutable
final class RegistryHeads {
  const RegistryHeads({this.curlMissing = false, this.images = const []});

  /// The host has no `curl`, so no image was checked.
  final bool curlMissing;
  final List<RegistryHeadRead> images;
}

const _keptHeaders = {
  'docker-content-digest',
  'content-type',
  'ratelimit-limit',
  'ratelimit-remaining',
  'www-authenticate',
};

final _statusLine = RegExp(r'^HTTP/[0-9.]+ ([0-9]{3})');

/// Reads [raw]; never throws. Lines outside an image's part are ignored.
RegistryHeads parseRegistryHeads(String raw) {
  final lines = raw.split('\n');
  if (lines.any((line) => line.trim() == kRegistryNoCurlMarker)) {
    return const RegistryHeads(curlMissing: true);
  }

  final images = <RegistryHeadRead>[];
  _ImageBuilder? current;
  var inCli = false;
  for (final rawLine in lines) {
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    if (line.startsWith('$kRegistryImageMarker ')) {
      if (current != null) images.add(current.build());
      current = _ImageBuilder(
        line.substring(kRegistryImageMarker.length + 1).trim(),
      );
      inCli = false;
      continue;
    }
    final image = current;
    if (image == null) continue;
    if (line.startsWith('$kRegistryHeadMarker ')) {
      image.curlExit = int.tryParse(
        line.substring(kRegistryHeadMarker.length + 1).trim(),
      );
      inCli = false;
      continue;
    }
    if (line.startsWith('$kRegistryCliMarker ')) {
      final rest = line.substring(kRegistryCliMarker.length + 1).trim();
      if (rest == 'missing') {
        image.cliMissing = true;
      } else {
        image.cliExit = int.tryParse(rest);
        inCli = true;
      }
      continue;
    }
    if (inCli) {
      image.cli.writeln(line);
      continue;
    }
    if (_statusLine.firstMatch(line) case final match?) {
      image.statusCode = int.parse(match.group(1)!);
      // A later response (after a proxy's or the token flow's) replaces
      // what came before.
      image.headers.clear();
      continue;
    }
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final name = line.substring(0, colon).trim().toLowerCase();
    if (!_keptHeaders.contains(name)) continue;
    image.headers.add((name, line.substring(colon + 1).trim()));
  }
  if (current != null) images.add(current.build());
  return RegistryHeads(images: images);
}

final class _ImageBuilder {
  _ImageBuilder(this.reference);

  final String reference;
  int? curlExit;
  int? statusCode;
  final headers = <(String, String)>[];
  int? cliExit;
  bool cliMissing = false;
  final cli = StringBuffer();

  RegistryHeadRead build() {
    final output = cli.toString().trim();
    return RegistryHeadRead(
      reference: reference,
      curlExit: curlExit,
      statusCode: statusCode,
      headers: List.unmodifiable(headers),
      cliExit: cliExit,
      cliMissing: cliMissing,
      cliOutput: output.isEmpty ? null : output,
    );
  }
}
