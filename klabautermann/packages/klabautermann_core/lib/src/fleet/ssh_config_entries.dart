import 'package:seance_core/seance_core.dart' show SshConfigImporter;

import '../engine/protocol.dart';

/// Prefixes an imported entry's alias to form its [FleetEntry.serverId].
/// Synced ids are bare UUIDs, so the two can never collide; import ids are
/// device-local and never become record ids.
const String _importIdPrefix = 'ssh-config:';

/// The TCP port range; a `Port` outside it names no reachable endpoint.
const int _minimumPort = 1;
const int _maximumPort = 65535;

/// Maps an OpenSSH client config's [text] to device-local fleet entries
/// (FL-02) through Séance's `SshConfigImporter`, so Klabautermann reads a
/// config exactly as Séance does. What the importer does, and so what this
/// does:
///
/// - one entry per `Host` block, named by its first non-wildcard pattern;
///   wildcard-only blocks such as `Host *` describe defaults, not hosts,
///   and are dropped (their defaults are not applied to other hosts);
/// - `HostName`, `Port` and `User` are read, a missing `HostName` falls back
///   to the alias as ssh does, and every other directive is ignored;
/// - `Match` blocks are ignored, and `Include` is not followed: the importer
///   drops the directive and the engine opens no file, so hosts defined only
///   in an included file are not imported;
/// - an unparsable `Port` reads as absent, so the entry gets port 22.
///
/// On top of the importer, a block is skipped and counted when its `Port`
/// is outside 1 to 65535, or when an earlier block already took its alias
/// (the alias is the entry's id; ssh would merge the two blocks, this keeps
/// the first). The text is parsed in the calling isolate: the engine's, so
/// a large config never stalls the UI (CN-19). The engine keeps the returned
/// entries as its import state, so the list is unmodifiable.
({List<FleetEntry> entries, int skippedCount}) fleetEntriesFromSshConfig(
  String text,
) {
  final entries = <FleetEntry>[];
  final aliases = <String>{};
  var skipped = 0;

  for (final host in SshConfigImporter.parse(text)) {
    final port = host.port ?? kSshDefaultPort;
    if (port < _minimumPort || port > _maximumPort) {
      skipped++;
      continue;
    }
    if (!aliases.add(host.alias)) {
      skipped++;
      continue;
    }

    entries.add(
      FleetEntry(
        serverId: '$_importIdPrefix${host.alias}',
        label: host.alias,
        // `HostName=` with no value is as good as absent.
        host: _nonEmpty(host.hostName) ?? host.alias,
        port: port,
        user: _nonEmpty(host.user),
        origin: FleetEntryOrigin.sshConfig,
      ),
    );
  }
  return (entries: List.unmodifiable(entries), skippedCount: skipped);
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;
