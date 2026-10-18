import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/workspace_remote_files.dart';
import '../services/document_workspace.dart';

typedef WorkspacePromptHost = ({
  BuildContext context,
  DocumentWorkspace workspace,
});

/// Resolves the active window at prompt time, including reconnects after the
/// original browser window closed. Secrets are never kept by the UI adapter.
final class AppWorkspaceConnectionPrompts
    implements WorkspaceConnectionPrompts {
  AppWorkspaceConnectionPrompts(
    this._host, {
    required Future<String?> Function(DocumentWorkspace host) pickKeyText,
  }) : // The picker belongs to the window; its field stays private.
       // ignore: prefer_initializing_formals
       _pickKeyText = pickKeyText;
  final WorkspacePromptHost? Function() _host;
  final Future<String?> Function(DocumentWorkspace host) _pickKeyText;

  Future<T> _withHost<T>(
    T cancelled,
    Future<T> Function(WorkspacePromptHost host) show,
  ) async {
    final host = _host();
    if (host == null || !host.context.mounted) return cancelled;
    Future<T> run() => Future.any([
      show(host),
      host.workspace.whenDisposed.then((_) => cancelled),
    ]);
    // The initiating operation may already own this window's modal lock.
    if (host.workspace.interactionLocked) return run();
    return await host.workspace.chooseWorkspace<T>(run) ?? cancelled;
  }

  @override
  Future<bool> trustHost(HostKeyDecision decision) =>
      _withHost(false, (host) async {
        final context = host.context;
        final key = decision.presented;
        return showGhostHostKeyDialog(
          context,
          GhostHostKeyPrompt(
            host: key.host,
            port: key.port,
            keyType: key.type,
            fingerprintSha256: key.fingerprintSha256,
            pinnedFingerprintSha256: decision.pinned?.fingerprintSha256,
            pinnedKeyType: decision.pinned?.type,
          ),
          monoStyle: const TextStyle(fontFamily: 'monospace'),
        );
      });

  @override
  Future<CredentialDraft?> credentials(
    ServerConfig server,
    CredentialResolutionScope scope,
  ) => _withHost<CredentialDraft?>(null, (host) async {
    final context = host.context;
    final dialogKey = GlobalKey();
    var finished = false;
    // Only this prompt's route may be withdrawn when its pool disappears.
    void withdraw() {
      if (finished || !context.mounted) return;
      final promptContext = dialogKey.currentContext;
      if (promptContext == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => withdraw());
        return;
      }
      final route = ModalRoute.of(promptContext);
      if (route != null) Navigator.of(promptContext).removeRoute(route);
    }

    scope.dismissed.then((_) => withdraw());
    try {
      final reply = await showGhostCredentialDialog(
        context,
        GhostCredentialRequest(
          authMethod: server.authMethod,
          endpointLabel: server.label,
          keyField: server.identityFilePath == null
              ? GhostKeyField.pastedPem
              : GhostKeyField.passphraseOnly,
          initialKeyPath: server.identityFilePath,
          username: server.username,
          host: server.host,
          port: server.port,
        ),
        monoStyle: const TextStyle(fontFamily: 'monospace'),
        dialogKey: dialogKey,
        pickKeyText: server.identityFilePath == null
            ? () => _pickKeyText(host.workspace)
            : null,
        strings: const GhostCredentialStrings(
          explanation: 'Used for this connection only.',
          connect: 'Connect',
        ),
      );
      return switch (reply) {
        GhostPasswordReply(:final password) => CredentialDraft(
          password: password,
        ),
        GhostPrivateKeyReply(:final privateKeyPem, :final keyPassphrase) =>
          CredentialDraft(
            privateKeyPem: privateKeyPem,
            keyPassphrase: keyPassphrase,
          ),
        GhostKeyPassphraseReply(:final keyPassphrase) => CredentialDraft(
          keyPassphrase: keyPassphrase,
        ),
        _ => null,
      };
    } finally {
      finished = true;
    }
  });

  @override
  Future<List<String>> keyboardInteractive(
    KeyboardInteractiveChallenge challenge,
  ) => _withHost<List<String>>(const [], (host) async {
    final context = host.context;
    return showGhostKeyboardInteractiveDialog(
      context,
      GhostKeyboardPrompt(
        username: challenge.server.username,
        host: challenge.server.host,
        port: challenge.server.port,
        name: challenge.name,
        instruction: challenge.instruction,
        prompts: challenge.prompts,
      ),
    );
  });
}
