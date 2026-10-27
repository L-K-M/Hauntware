/// IMG-05's digest update check (03 §7.14, D68): the local digests from
/// the daemon, the registry digests from the host, compared, and kept
/// for six hours per reference.
library;

import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show ChannelOpenException, RemoteCommandException, quoteShellWord;

import '../engine/protocol.dart';
import 'stack_sources.dart' show StackCheckWaiting, StackCommandRunner;

/// How long a reference's result stands before a check reads it again
/// (03 §7.14 IMG-05).
const Duration kImageUpdateFresh = Duration(hours: 6);

/// How long a registry is left alone after a `429` that named no window
/// (D68: Docker Hub names one hour).
const Duration kImageUpdateBackoff = Duration(hours: 1);

/// How long one batch of up to [kRegistryHeadsMax] references may run:
/// each `HEAD` and token request has curl's own 20 s limit.
const Duration kImageUpdateCommandTimeout = Duration(minutes: 3);

/// The output one batch keeps: about 600 bytes a reference, more where
/// buildx prints a manifest.
const int kImageUpdateMaxOutputBytes = 1024 * 1024;

/// What a server's checks remember between queries, owned by the router:
/// each reference's last row and each registry's backoff after a `429`.
final class ImageUpdateCache {
  final Map<String, ImageUpdateRow> _rows = {};
  final Map<String, DateTime> _backoffUntil = {};

  /// The last row for [reference], fresh or not.
  ImageUpdateRow? row(String reference) => _rows[reference];

  /// Forgets everything, as when the server leaves the fleet.
  void clear() {
    _rows.clear();
    _backoffUntil.clear();
  }
}

/// One tag to check, the image it names and where its read goes.
typedef _Entry = ({
  String tag,
  RegistryReference reference,
  ImageSummary image,
  RegistryHeadTarget target,
});

/// Checks every tagged image on [client]'s daemon (IMG-05): references
/// read within [kImageUpdateFresh] keep their row unless [refresh]; the
/// rest go to the host through [run] in batches of [kRegistryHeadsMax].
/// A registry that answered `429` is skipped until the window it named
/// has passed, and never falls back to DistributionInspect (D68).
Future<DockerPayload> checkImageUpdates({
  required DockerClient client,
  required StackCommandRunner run,
  required ImageUpdateCache cache,
  required DateTime now,
  bool refresh = false,
  ImageCheckRunner runner = ImageCheckRunner.host,
}) async {
  final images = (await client.listImages()).value;
  final entries = <_Entry>[
    for (final image in images)
      for (final tag in image.repoTags)
        if (RegistryReference.tryParse(tag) case final reference?
            when !reference.isPinned)
          if (_target(tag, reference) case final target?)
            (tag: tag, reference: reference, image: image, target: target),
  ];

  final due = [
    for (final entry in entries)
      if (refresh || _stale(cache.row(entry.tag), now))
        if (!_backingOff(cache, entry.reference.registry, now)) entry,
  ];

  var curlMissing = false;
  if (due.isNotEmpty && runner == ImageCheckRunner.daemon) {
    final local = await _localDigests(client, due.map((e) => e.image.id));
    for (final entry in due) {
      // One registry's 429 holds back its later tags in this check too.
      if (_backingOff(cache, entry.reference.registry, now)) continue;
      final head = await _daemonHead(client, entry.tag);
      _keep(
        cache,
        entry,
        _row(
          entry,
          local[entry.image.id],
          now,
          head: head,
          route: ImageUpdateRoute.daemon,
        ),
        now,
      );
    }
  } else if (due.isNotEmpty) {
    final local = await _localDigests(client, due.map((e) => e.image.id));
    for (var start = 0; start < due.length; start += kRegistryHeadsMax) {
      final batch = due.skip(start).take(kRegistryHeadsMax).toList();
      final heads = await _readHeads(run, batch);
      if (heads == null) {
        return const DockerQueryFailed(
          DockerQueryFailure.connectionFailed,
          detail: 'the registry check could not run on the server',
        );
      }
      if (heads.curlMissing) {
        curlMissing = true;
        break;
      }
      final byTag = {for (final read in heads.images) read.reference: read};
      for (final entry in batch) {
        final read = byTag[entry.tag];
        final (head, route) = _head(read);
        _keep(
          cache,
          entry,
          _row(
            entry,
            local[entry.image.id],
            now,
            head: head,
            route: route,
            cliMissing: read?.cliMissing ?? false,
            rateLimit: read == null
                ? null
                : RegistryRateLimit.fromHeaders(HttpHeaders(read.headers)),
          ),
          now,
        );
      }
    }
  }

  return DockerImageUpdatesPayload([
    for (final entry in entries)
      if (cache.row(entry.tag) case final row?) row,
  ], curlMissing: curlMissing);
}

/// [reference]'s read, or null when the host command would refuse one
/// of its words: a tag Docker accepts but the command's stricter checks
/// do not is left unchecked rather than failing every other image.
RegistryHeadTarget? _target(String tag, RegistryReference reference) {
  final target = RegistryHeadTarget(
    registry: reference.registry,
    repository: reference.repository,
    tag: reference.tag,
    reference: tag,
  );
  try {
    HostCommands.registryHeads([target]);
    return target;
  } on HostCommandError {
    return null;
  }
}

bool _stale(ImageUpdateRow? row, DateTime now) =>
    row == null || now.difference(row.checkedAt) >= kImageUpdateFresh;

bool _backingOff(ImageUpdateCache cache, String registry, DateTime now) {
  final until = cache._backoffUntil[registry];
  return until != null && now.isBefore(until);
}

/// Each image's containerd `Descriptor` and available index children,
/// one inspect at a time: on a relay each holds the one pooled
/// connection. An image gone before its inspect is left out.
Future<Map<String, ImageInspect>> _localDigests(
  DockerClient client,
  Iterable<String> ids,
) async {
  final inspected = <String, ImageInspect>{};
  for (final id in ids.toSet()) {
    try {
      inspected[id] = (await client.inspectImage(id, manifests: true)).value;
    } on DockerNotFoundException {
      continue;
    }
  }
  return inspected;
}

/// Runs one batch on the host; null when the command could not run.
Future<RegistryHeads?> _readHeads(
  StackCommandRunner run,
  List<_Entry> batch,
) async {
  final argv = HostCommands.registryHeads([
    for (final entry in batch) entry.target,
  ]);
  try {
    final result = await run(
      HostCommands.commandLine(argv, quote: quoteShellWord),
      timeout: kImageUpdateCommandTimeout,
      maxOutputBytes: kImageUpdateMaxOutputBytes,
    );
    return parseRegistryHeads(result.stdout);
  } on RemoteCommandException {
    return null;
  } on ChannelOpenException {
    return null;
  } on StackCheckWaiting {
    return null;
  }
}

/// Keeps [row], and starts its registry's backoff after a `429`.
void _keep(
  ImageUpdateCache cache,
  _Entry entry,
  ImageUpdateRow row,
  DateTime now,
) {
  cache._rows[entry.tag] = row;
  if (row.comparison.issue != ImageUpdateIssue.rateLimited) return;
  cache._backoffUntil[entry.reference.registry] = now.add(
    row.rateLimit?.window ?? kImageUpdateBackoff,
  );
}

/// [tag]'s registry digest by DistributionInspect, with the daemon's
/// refusal as the status it stands for. Null when the daemon could not
/// be asked.
Future<RegistryManifestHead?> _daemonHead(
  DockerClient client,
  String tag,
) async {
  try {
    final descriptor = (await client.distributionInspect(tag)).value;
    return RegistryManifestHead(
      statusCode: 200,
      digest: descriptor.digest,
      mediaType: descriptor.mediaType,
    );
  } on DockerApiException catch (e) {
    // The daemon passes the registry's error on in its message: spike S8
    // saw "no basic auth credentials" from a private registry, and
    // Docker Hub names a spent quota `toomanyrequests`.
    final message = e.message.toLowerCase();
    return RegistryManifestHead(
      statusCode: message.contains('toomanyrequests')
          ? 429
          : message.contains('credentials') ||
                message.contains('unauthorized') ||
                message.contains('denied')
          ? 401
          : e.statusCode,
    );
  } on DockerException {
    return null;
  }
}

ImageUpdateRow _row(
  _Entry entry,
  ImageInspect? inspect,
  DateTime now, {
  required RegistryManifestHead? head,
  required ImageUpdateRoute route,
  bool cliMissing = false,
  RegistryRateLimit? rateLimit,
}) {
  final repoDigests = inspect?.repoDigests ?? entry.image.repoDigests;
  return ImageUpdateRow(
    reference: entry.tag,
    imageId: entry.image.id,
    comparison: compareImageDigest(
      repoDigests: repoDigests,
      repository: entry.reference.familiarName,
      tag: entry.reference.tag,
      remote: head,
      descriptorDigest: inspect?.descriptorDigest,
      availableChildDigests: inspect?.availableChildDigests ?? const [],
    ),
    checkedAt: now,
    route: head?.digest == null ? null : route,
    cliMissing: cliMissing,
    rateLimit: rateLimit,
  );
}

/// The registry's answer as a [RegistryManifestHead]: buildx's manifest
/// when the CLI read it, the `HEAD` otherwise; null when curl got no
/// answer.
(RegistryManifestHead?, ImageUpdateRoute) _head(RegistryHeadRead? read) {
  if (read == null) return (null, ImageUpdateRoute.registry);
  if (read.cliExit == 0) {
    if (_cliManifest(read.cliOutput) case final manifest?) {
      return (manifest, ImageUpdateRoute.hostCli);
    }
  }
  final status = read.statusCode;
  if (status == null) return (null, ImageUpdateRoute.registry);
  return (
    RegistryManifestHead(
      statusCode: status,
      digest: read.header('docker-content-digest'),
      mediaType: read.header('content-type'),
    ),
    ImageUpdateRoute.registry,
  );
}

/// buildx's `{{json .Manifest}}`: the descriptor of what the tag names.
RegistryManifestHead? _cliManifest(String? output) {
  if (output == null) return null;
  try {
    final decoded = jsonDecode(output);
    if (decoded is! Map) return null;
    final digest = decoded['digest'];
    if (digest is! String || !digest.startsWith('sha256:')) return null;
    final mediaType = decoded['mediaType'];
    return RegistryManifestHead(
      statusCode: 200,
      digest: digest,
      mediaType: mediaType is String ? mediaType : null,
    );
  } on FormatException {
    return null;
  }
}
