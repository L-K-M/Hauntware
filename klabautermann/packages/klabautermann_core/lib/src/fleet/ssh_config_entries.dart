import 'package:seance_core/seance_core.dart' show SshConfigImporter;

import '../engine/protocol.dart';

/// Prefixes an imported entry's alias to form its [FleetEntry.serverId].
/// Synced ids are bare UUIDs, so the two can never collide; import ids are
/// device-local and never become record ids.
const String _importIdPrefix = 'ssh-config:';

/// Maps an OpenSSH client config's [text] to device-local fleet entries
/// (FL-02) through Séance's `SshConfigImporter`, so Klabautermann reads a
/// config exactly as Séance does. What the importer does, and so what this
/// does:
///
/// - one entry per name a `Host` line gives, with its block's settings:
///   `Host a b` makes `a` and `b`. Wildcard and negated patterns are not
///   names, so blocks such as `Host *` describe defaults, not hosts, and
///   are dropped (their defaults are not applied to other hosts);
/// - `HostName`, `Port` and `User` are read, a missing `HostName` falls back
///   to the alias as ssh does, and every other directive is ignored;
/// - `Match` blocks are ignored, and `Include` is not followed: the importer
///   drops the directive and the engine opens no file, so hosts defined only
///   in an included file are not imported;
/// - `Port` is a decimal 1 to 65535 or the service name `ssh`, `http` or
///   `https`; a block with any other `Port` is skipped, where ssh would
///   reject the whole config, and its hosts are counted.
///
/// On top of the importer, a host is skipped and counted when an earlier
/// block already took its alias (the alias is the entry's id; ssh would
/// merge the two blocks, this keeps the first). The text is parsed in the
/// calling isolate: the engine's, so a large config never stalls the UI
/// (CN-19). The engine keeps the returned entries as its import state, so
/// the list is unmodifiable.
({List<FleetEntry> entries, int skippedCount}) fleetEntriesFromSshConfig(
  String text,
) {
  final entries = <FleetEntry>[];
  final aliases = <String>{};
  final parsed = SshConfigImporter.parse(text);
  var skipped = parsed.skipped.length;

  for (final host in parsed.hosts) {
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
        port: host.port ?? kSshDefaultPort,
        user: _nonEmpty(host.user),
        origin: FleetEntryOrigin.sshConfig,
      ),
    );
  }
  return (entries: List.unmodifiable(entries), skippedCount: skipped);
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;
