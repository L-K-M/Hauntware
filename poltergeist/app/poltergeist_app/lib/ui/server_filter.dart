// Ported from Séance app/seance_app/lib/ui/server_filter.dart @ ded9228; see docs/PORTS.md.
/// The text the server list's filter searches.
///
/// Kept free of Flutter so the matching rules can be unit-tested directly.
/// The sidebar splits a query on whitespace and **every** term must match
/// somewhere in this haystack (`sidebarQueryMatches`) — so `web eu` finds
/// `prod-web-01.eu-west` without the user having to remember which order the
/// parts appear in, and `root 2222` finds the one host reached as root on a
/// non-standard port.
library;

import 'package:poltergeist_core/poltergeist_core.dart';

/// The searchable text of one server: label, user, host, port, and group.
///
/// The group is in here so that typing a section's name narrows the list to
/// that section — the filter and the grouping answer the same question from
/// two directions, and a `prod` that matched the header but not the rows would
/// be a strange thing to explain.
String serverSearchHaystack(ServerConfig server) =>
    '${server.label} ${server.username}@${server.host}:${server.port} '
            '${server.group ?? ''}'
        .toLowerCase();
