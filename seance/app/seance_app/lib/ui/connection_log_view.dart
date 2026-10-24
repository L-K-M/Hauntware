import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart' show GhostConnectionLogView;

import '../theme.dart' show SeanceTheme;
import 'ghost_servers_adapter.dart' show logConnectionLogCopyError;

/// A collapsible view of a raw SSH connection transcript, with a copy button:
/// ghost_servers' [GhostConnectionLogView] in Séance's words and face, with a
/// failed copy logged.
///
/// Takes the text rather than a session so both places that show a transcript
/// (a failed terminal tab and the server editor's connection test) read the
/// same. Redaction is the producer's contract: `SshConnectionLog` enforces it
/// at capture, so [text] is shown and copied verbatim.
class ConnectionLogView extends StatelessWidget {
  final String text;
  const ConnectionLogView({super.key, required this.text});

  @override
  Widget build(BuildContext context) => GhostConnectionLogView(
    text: text,
    monoStyle: SeanceTheme.mono,
    onCopyError: logConnectionLogCopyError,
  );
}
