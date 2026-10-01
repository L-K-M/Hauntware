import 'dart:convert';

import 'package:seance_core/seance_core.dart';

/// Canonical import endpoint key. Hosts are case-insensitive; usernames are
/// kept verbatim because their case rules depend on the server.
String bookmarkImportEndpointKey(String host, int port, String username) =>
    jsonEncode([host.toLowerCase(), port, username]);

/// Canonical third-party destination key. Unlike ssh_config imports, one
/// endpoint can intentionally own several bookmarked remote paths.
String bookmarkImportDestinationKey(
  String host,
  int port,
  String username,
  String remotePath,
) => jsonEncode([host.toLowerCase(), port, username, remotePath]);

/// Indexes every embedded endpoint a bookmark owns, including workspace and
/// sync sides. Catalog references cannot be compared until connect time.
Map<String, String> existingBookmarkImportEndpoints(
  Iterable<Bookmark> bookmarks,
) {
  final endpoints = <String, String>{};
  for (final bookmark in bookmarks) {
    for (final reference in _bookmarkServerReferences(bookmark)) {
      final identity = reference.identity;
      if (identity == null) continue;

      endpoints[bookmarkImportEndpointKey(
            identity.host,
            identity.port,
            identity.username,
          )] =
          bookmark.label;
    }
  }

  return endpoints;
}

/// Indexes every embedded remote destination, including workspace and sync
/// sides. Local sides and catalog references cannot match an imported path.
Map<String, String> existingBookmarkImportDestinations(
  Iterable<Bookmark> bookmarks,
) {
  final destinations = <String, String>{};
  for (final bookmark in bookmarks) {
    for (final destination in _bookmarkRemoteDestinations(bookmark)) {
      final identity = destination.reference.identity;
      if (identity == null) continue;

      destinations[bookmarkImportDestinationKey(
            identity.host,
            identity.port,
            identity.username,
            destination.path,
          )] =
          bookmark.label;
    }
  }

  return destinations;
}

Iterable<BookmarkServerRef> _bookmarkServerReferences(Bookmark bookmark) sync* {
  final server = bookmark.server;
  if (server != null) yield server;

  final left = bookmark.left?.server;
  if (left != null) yield left;

  final right = bookmark.right?.server;
  if (right != null) yield right;

  final source = bookmark.sync?.source.server;
  if (source != null) yield source;

  final destination = bookmark.sync?.destination.server;
  if (destination != null) yield destination;
}

Iterable<({BookmarkServerRef reference, String path})>
_bookmarkRemoteDestinations(Bookmark bookmark) sync* {
  final server = bookmark.server;
  final remotePath = bookmark.remotePath;
  if (server != null && remotePath != null) {
    yield (reference: server, path: remotePath);
  }

  final left = bookmark.left;
  if (left?.server != null) {
    yield (reference: left!.server!, path: left.path);
  }

  final right = bookmark.right;
  if (right?.server != null) {
    yield (reference: right!.server!, path: right.path);
  }

  final source = bookmark.sync?.source;
  if (source?.server != null) {
    yield (reference: source!.server!, path: source.path);
  }

  final destination = bookmark.sync?.destination;
  if (destination?.server != null) {
    yield (reference: destination!.server!, path: destination.path);
  }
}
