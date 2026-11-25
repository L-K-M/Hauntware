import 'package:meta/meta.dart';

import 'equality.dart' show sameItems;

/// A synced server's or jump host's endpoint as the confirmation list
/// showed it ([ConfirmEndpoints.shown]): the [FleetEntry] fields a
/// confirmation pins. A route's hops need their own entries here; the
/// route on a server names them by label only.
@immutable
final class ShownEndpoint {
  const ShownEndpoint({
    required this.host,
    required this.port,
    this.user,
    this.jumpRoute,
  });

  /// [entry]'s endpoint.
  ShownEndpoint.of(FleetEntry entry)
    : host = entry.host,
      port = entry.port,
      user = entry.user,
      jumpRoute = entry.jumpRoute;

  final String host;
  final int port;
  final String? user;

  /// As [FleetEntry.jumpRoute]. Pass an unmodifiable list.
  final List<String>? jumpRoute;

  @override
  bool operator ==(Object other) =>
      other is ShownEndpoint &&
      host == other.host &&
      port == other.port &&
      user == other.user &&
      sameItems(jumpRoute, other.jumpRoute);

  @override
  int get hashCode => Object.hash(
    host,
    port,
    user,
    jumpRoute == null ? null : Object.hashAll(jumpRoute!),
  );
}

/// The port SSH uses when a config names none (RFC 4253, section 4.1).
const int kSshDefaultPort = 22;

/// Where a [FleetEntry] came from, which decides what may happen to it.
enum FleetEntryOrigin {
  /// A `serverConfig` record pulled from the shared Séance sync account
  /// (D13); read-only in the MVP (D14), edited through [SaveServer] and
  /// [DeleteServer] since v1.
  synced,

  /// Imported on this device from an OpenSSH client config (FL-02, 03
  /// §4.2). Device-local and never pushed in the MVP; the engine keeps the
  /// set in `ssh_config_imports.json` (03 §4.10).
  sshConfig,
}

/// One server as the fleet rail lists it (03 §10.1, §10.3): its identity
/// and endpoint, and nothing the rail does not need yet. The catalog's
/// full records stay engine-side; this is the plain data that crosses the
/// isolate boundary (D18).
@immutable
final class FleetEntry {
  const FleetEntry({
    required this.serverId,
    required this.label,
    required this.host,
    required this.port,
    required this.origin,
    this.user,
    this.group,
    this.jumpRoute,
    this.authKind,
    this.searchText,
    this.locatorConflict,
    this.endpoint,
    this.excludedFromSync = false,
  });

  /// The id every per-server request carries: a synced record's bare
  /// UUID, or `ssh-config:<alias>` for an import. Import ids are
  /// device-local and never reach the sync server.
  final String serverId;

  /// The name the rail shows: the record's label or the config's alias.
  final String label;

  /// The host name or address SSH connects to.
  final String host;

  /// The SSH port, [kSshDefaultPort] unless the source names another.
  final int port;

  /// The login name the source names; null when it names none, and the
  /// engine then signs in as the local account (`USER` or `USERNAME`).
  final String? user;

  /// The group the rail files the entry under, or null for none. An
  /// ssh_config has no groups, so imports always carry null.
  final String? group;

  final FleetEntryOrigin origin;

  /// The jump hosts the engine connects through, first hop first, each as
  /// its source names it (an ssh_config alias, or `[user@]host[:port]`);
  /// null for a direct connection, and for an import whose route is
  /// unknown: one from an older import store (03 §4.10), which the engine
  /// marks by sending no [authKind]. Pass an unmodifiable list.
  final List<String>? jumpRoute;

  /// How the engine signs in to the server, or null when the source does
  /// not say.
  final FleetAuthKind? authKind;

  /// The lowercase text the rail's filter matches, built by the engine
  /// with `seance_protocol`'s `serverSearchHaystack`, which the app may not
  /// import (03 §3.2); null when the engine built none.
  final String? searchText;

  /// The server ids of the other entries that pin a host key at one of
  /// this entry's pin locators (`host:port`: the server's or a jump hop's)
  /// behind a different jump route, whose pins would collide (03 §4.6);
  /// null when none do, and for an import whose route is unknown (see
  /// [jumpRoute]). Pass an unmodifiable list.
  final List<String>? locatorConflict;

  /// Whether this device confirmed a synced server's endpoint (03 §4.7);
  /// null for an import, which counts as confirmed on the device that
  /// imported it.
  final EndpointConfirmation? endpoint;

  /// Whether a synced server stays on this device only, so its
  /// preferences do not sync (03 §4.8); false for an import.
  final bool excludedFromSync;

  // By value: every CatalogReplaced copies its entries across the isolate
  // boundary, so identity would make an unchanged entry look changed.
  @override
  bool operator ==(Object other) =>
      other is FleetEntry &&
      serverId == other.serverId &&
      label == other.label &&
      host == other.host &&
      port == other.port &&
      user == other.user &&
      group == other.group &&
      origin == other.origin &&
      sameItems(jumpRoute, other.jumpRoute) &&
      authKind == other.authKind &&
      searchText == other.searchText &&
      sameItems(locatorConflict, other.locatorConflict) &&
      endpoint == other.endpoint &&
      excludedFromSync == other.excludedFromSync;

  @override
  int get hashCode => Object.hash(
    serverId,
    label,
    host,
    port,
    user,
    group,
    origin,
    jumpRoute == null ? null : Object.hashAll(jumpRoute!),
    authKind,
    searchText,
    locatorConflict == null ? null : Object.hashAll(locatorConflict!),
    endpoint,
    excludedFromSync,
  );
}

/// Where a synced server's endpoint stands on this device (03 §4.7,
/// SAF-09). Only a [confirmed] one is dialed.
enum EndpointConfirmation {
  /// Its host, port, user and jump route match what this device
  /// confirmed, and so does each jump host's.
  confirmed,

  /// Never confirmed on this device.
  unconfirmed,

  /// Confirmed once, but a sync has changed it or a jump host on its
  /// route since: it waits to be confirmed again.
  changed,
}

/// How the engine signs in to a [FleetEntry]'s server (03 §4.5).
enum FleetAuthKind {
  /// An ssh-agent signs; the device stores nothing.
  agent,

  /// A private key file on this device, read by its path (an ssh_config
  /// `IdentityFile`).
  identityFile,

  /// A private key held in the vault.
  storedKey,

  /// A password, from the vault or asked for.
  password,
}

/// What went wrong with `ssh_config_imports.json` when the engine started
/// (03 §4.10). In every case the engine started without imports.
enum ImportStoreIssueKind {
  /// The file was not an import store this build can read. It was renamed
  /// to [ImportStoreIssue.preservedAs], byte for byte, and the next import
  /// saves a new file.
  recovered,

  /// The file could not be read, or it was damaged and could not be
  /// renamed aside. It is left as it is, and imports are not saved while
  /// this engine runs, so nothing replaces bytes nobody has kept.
  leftAsIs,

  /// A newer build wrote the file. It is left as it is, and imports are not
  /// saved while this engine runs, so the newer build finds its own file.
  newerVersion,
}

/// The problem the engine met loading `ssh_config_imports.json`, carried by
/// [EngineReady]. Plain data: the underlying error crosses as text.
@immutable
final class ImportStoreIssue {
  const ImportStoreIssue(this.kind, {this.preservedAs, this.detail});

  final ImportStoreIssueKind kind;

  /// The damaged file's new path; set for [ImportStoreIssueKind.recovered]
  /// only.
  final String? preservedAs;

  /// The failure behind [kind], for diagnostics only.
  final String? detail;
}
