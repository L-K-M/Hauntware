import 'package:flutter/widgets.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:seance_core/seance_core.dart';

import '../services/missing_credential.dart';
import '../services/private_key_file.dart';
import '../theme.dart' show SeanceTheme;
import 'ghost_servers_adapter.dart';

/// Asks for the credential a tab could not find on this device (CRED-05's
/// inline prompt): the server's password, or its private key. Null when the
/// user cancels. [pickKeyText] reads a key file; a test supplies its own.
///
/// The dialog lives in Planchette's `ghost_servers` since 2026-10-16
/// (docs/design/ghost-servers-part1.md, PR 6); its default words are
/// Séance's, so only the request, the key picker and the monospace stack
/// go in. A tap outside still cancels the prompt (`barrierDismissible`).
Future<MissingCredential?> showMissingCredentialDialog(
  BuildContext context, {
  required String serverLabel,
  required AuthMethod authMethod,
  Future<String?> Function() pickKeyText = pickPrivateKeyText,
}) async {
  final reply = await showGhostCredentialDialog(
    context,
    ghostCredentialRequestOf(serverLabel: serverLabel, authMethod: authMethod),
    pickKeyText: pickKeyText,
    monoStyle: SeanceTheme.mono,
    barrierDismissible: true,
  );
  return reply == null ? null : missingCredentialOf(reply);
}

/// Asks only for a known key's passphrase. No PEM or key file is copied
/// into the dialog; the existing key source stays under the app services.
Future<KeyPassphraseAnswer?> showKeyPassphraseDialog(
  BuildContext context, {
  required ServerConfig server,
  bool retry = false,
}) async {
  final reply = await showGhostCredentialDialog(
    context,
    ghostKeyPassphraseRequestOf(server),
    strings: GhostCredentialStrings(
      passwordTitle: (label) => 'Key passphrase for $label',
      explanation: retry
          ? 'That passphrase did not open the key. Try again.'
          : 'Used for this connection only, unless you choose Save in vault.',
      passwordField: 'Passphrase',
      connect: 'Connect',
    ),
    monoStyle: SeanceTheme.mono,
    barrierDismissible: true,
  );
  return switch (reply) {
    null => null,
    GhostKeyPassphraseReply(:final keyPassphrase, :final saveToVault) =>
      KeyPassphraseAnswer(keyPassphrase, saveToVault: saveToVault),
    GhostPasswordReply(:final password, :final saveToVault) =>
      KeyPassphraseAnswer(password, saveToVault: saveToVault),
    GhostPrivateKeyReply() =>
      throw StateError('The passphrase prompt cannot replace a private key'),
  };
}
