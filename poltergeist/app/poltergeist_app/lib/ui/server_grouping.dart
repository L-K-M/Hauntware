// Partly ported from Séance app/seance_app/lib/ui/server_grouping.dart @ 8326f41f574fabce11986ea16137917626f67958: only existingServerGroups is carried; see docs/PORTS.md.
/// The server editor's group suggestions.
///
/// Séance's file also sections its server list; Poltergeist's catalog groups
/// its servers inline, so only the editor's helper is carried here.
library;

import 'package:poltergeist_core/poltergeist_core.dart';

/// The distinct group names in [servers], sorted, for offering existing groups
/// in the editor instead of making the user retype (and misspell) one.
List<String> existingServerGroups(List<ServerConfig> servers) {
  final names = <String, String>{};
  for (final server in servers) {
    final group = normalizeServerGroup(server.group);
    if (group != null) names.putIfAbsent(serverGroupKey(group), () => group);
  }
  final keys = names.keys.toList()..sort();
  return [for (final key in keys) names[key]!];
}
