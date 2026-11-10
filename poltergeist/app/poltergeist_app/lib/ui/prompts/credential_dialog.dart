// The dialog lives in Planchette's ghost_servers since 2026-10-16
// (docs/design/ghost-servers-part1.md, PR 6b). This delegate keeps the
// divergences: the engine protocol's CredentialPromptData as the payload
// (03 §5), ARB strings (D20), the injected audited identity-file reader
// (D18) and CredentialDialogResult as the answer.
import 'package:flutter/widgets.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart' show poltergeistMonoTextStyle;
import '../ghost_servers_adapter.dart';

/// What the user answered to a credential prompt. Exactly one secret shape
/// is set — the password, or the identity file's key material (read from
/// disk by the dialog's submit path, so the coordinator never re-reads it).
class CredentialDialogResult {
  final String? password;
  final String? privateKeyPem;
  final String? keyPassphrase;

  /// True when the user asked to store the answer in the local vault under
  /// the config's secretRef (04 §2.1: "offers to save under the same id").
  final bool saveToVault;

  const CredentialDialogResult({
    this.password,
    this.privateKeyPem,
    this.keyPassphrase,
    this.saveToVault = false,
  });
}

/// The connect-time credential prompt (07 §3.3): shown when the vault holds
/// no secret for the server. Fields follow the auth method — a password, or
/// a key-file path plus passphrase; [readKeyFile] (the coordinator's
/// audited identity-file reader, D18) is injected so the dialog never
/// touches the filesystem itself and tests need no files.
///
/// Pass [request] and [retry] for the passphrase-only form, which asks for
/// the passphrase of a key whose material is already known.
Future<CredentialDialogResult?> showCredentialDialog(
  BuildContext context,
  CredentialPromptData data, {
  GhostCredentialRequest? request,
  bool retry = false,
  Future<String> Function(String path)? readKeyFile,
  bool vaultUnavailable = false,
  GlobalKey? dialogKey,
}) async {
  final l10n = AppLocalizations.of(context);
  final passphraseOnly = request?.keyField == GhostKeyField.passphraseOnly;
  final reply = await showGhostCredentialDialog(
    context,
    request ?? ghostCredentialRequestOf(data, vaultUnavailable: vaultUnavailable),
    strings: passphraseOnly
        ? poltergeistPassphraseStrings(l10n, retry: retry)
        : poltergeistCredentialStrings(l10n),
    readKeyFile: readKeyFile,
    monoStyle: poltergeistMonoTextStyle,
    dialogKey: dialogKey,
  );
  return _resultOf(reply);
}

CredentialDialogResult? _resultOf(GhostCredentialReply? reply) =>
    switch (reply) {
      null => null,
      GhostPasswordReply(:final password, :final saveToVault) =>
        CredentialDialogResult(password: password, saveToVault: saveToVault),
      GhostPrivateKeyReply(
        :final privateKeyPem,
        :final keyPassphrase,
        :final saveToVault,
      ) =>
        CredentialDialogResult(
          privateKeyPem: privateKeyPem,
          keyPassphrase: keyPassphrase,
          saveToVault: saveToVault,
        ),
      GhostKeyPassphraseReply(:final keyPassphrase, :final saveToVault) =>
        CredentialDialogResult(
          keyPassphrase: keyPassphrase,
          saveToVault: saveToVault,
        ),
    };
