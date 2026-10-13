// The production [ServerEditorDelegate]: what the editor's seams resolve to
// when the catalog drives it. Written to the shape Séance's AppState +
// AppServices answered (testServerConnection/resolveCredentials @ 5d578b9),
// recomposed over Poltergeist's services — see docs/PORTS.md.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../ui/prompts/host_key_dialog.dart';
import '../ui/prompts/keyboard_interactive_dialog.dart';
import '../ui/server_editor.dart';
import 'bookmark_backup_service.dart';
import 'identity_file_reader.dart';
import 'transfer_limits_controller.dart';

// Keep the editor trial on the same bounded-route contract as PR-S4.
const _maximumJumpHosts = 16;

enum _JumpRouteFailure { cycle, overlong, missing }

/// The application layer behind the server editor: catalog truth and sync
/// writes through [BookmarkBackupService], credential reads through the
/// dynamic vault, the connection test over the real transport with the
/// trial-pin semantics upstream's `testServerConnection` carries.
final class ServerEditorBackend extends ServerEditorDelegate {
  ServerEditorBackend({
    required this._backups,
    required this._vault,
    required this._hostKeys,
    required this._identityReader,
    required this._navigatorKey,
    required this._transferLimits,
  });

  final BookmarkBackupService _backups;

  /// The resolving vault (dynamic_secret_vault.dart): re-reads the current
  /// key per call, so an enrollment rekey mid-edit does not strand the
  /// editor's credential paths on a dead generation.
  final SecretVault _vault;
  final HostKeyStore _hostKeys;
  final IdentityFileReader _identityReader;
  final GlobalKey<NavigatorState> _navigatorKey;
  final TransferLimitsController _transferLimits;

  /// The shared decision table (draft over vault, drafts read only under
  /// their own auth method) over this editor's vault and identity reader.
  /// `substituteEmpty` keeps this path's answer to a named vault entry this
  /// device lacks: an empty credential, not an error. Switching it to
  /// `fail` is a separate behaviour change.
  late final _credentials = CredentialResolver(
    _EditorCredentialSource(_vault, _identityReader),
    missingSecretPolicy: MissingSecretPolicy.substituteEmpty,
  );

  @override
  List<ServerConfig> get servers =>
      _backups.catalog?.servers ?? const <ServerConfig>[];

  @override
  bool get syncConfigured => _backups.account != null;

  @override
  Color get themeSeed => poltergeistSeedColor;

  @override
  Future<String?> pickIdentityFile() async {
    final result = await FilePicker.pickFiles();
    final files = result?.files ?? const [];
    if (files.isEmpty) return null;
    // No withData: the path is what is stored — "reference, don't store"
    // reads the key at connect, so there is nothing to do with bytes here.
    return files.single.path;
  }

  @override
  Future<Secret?> readSecret(String secretId) =>
      _backups.serverSecretById(secretId);

  /// Credential first, config second — the order upstream's save keeps, and
  /// load-bearing here: [BookmarkBackupService.saveServer] publishes the
  /// opted-in `secret:` record, which reads the vault, so the entry must
  /// exist before the config names it; and a config write that then failed
  /// leaves only a vault entry nothing references (the retried save reuses
  /// the draft id and adopts it).
  @override
  Future<void> save(ServerConfig config, {Secret? secret}) async {
    if (secret != null) await _backups.saveServerSecret(secret);
    await _backups.saveServer(config);
  }

  @override
  TransferConcurrency get defaultTransferConcurrency =>
      _transferLimits.perServer;

  @override
  TransferConcurrency? transferConcurrencyFor(String serverId) =>
      _transferLimits.overrideFor(serverId);

  @override
  Future<void> saveTransferConcurrency(
    String serverId,
    TransferConcurrency? value,
  ) => _transferLimits.setOverride(serverId, value);

  /// Authenticate without a shell — upstream's `testServerConnection` shape:
  /// draft fields outrank the vault so the test reports on what the form
  /// says, and a trial host-key approval is pinned for the attempt only
  /// ([liveHostAuthenticator] wraps the store in `UnpinnedHostKeyStore`
  /// itself, so this call cannot be wired to pin).
  @override
  Future<ConnectionTestResult> testConnection(
    ServerConfig config, {
    String? draftPassword,
    String? draftPrivateKey,
    String? draftKeyPassphrase,
    SshConnectionLog? log,
  }) {
    final transcript = log ?? SshConnectionLog();
    late final Map<String, ServerConfig> jumpHosts;

    return runConnectionTest(
      config: config,
      credentials: () {
        // Freeze and validate the secret-free route before the first vault
        // or identity-file read. The authenticator then consumes this exact
        // snapshot even if sync replaces the catalog during an async read.
        jumpHosts = _snapshotJumpHosts(config, transcript);

        return _credentials.resolve(
          config,
          draft: CredentialDraft(
            password: draftPassword,
            privateKeyPem: draftPrivateKey,
            keyPassphrase: draftKeyPassphrase,
          ),
        );
      },
      authenticate: liveHostAuthenticator(
        hostKeys: _hostKeys,
        onHostKey: _promptForHostKey,
        onKeyboardInteractive: _promptKeyboardInteractive,
        // Saved hops come from the route snapshot captured before secrets.
        resolveJumpHost: _credentials.jumpHostResolver(
          (serverId) async => jumpHosts[serverId],
        ),
      ),
      log: transcript,
    );
  }

  Map<String, ServerConfig> _snapshotJumpHosts(
    ServerConfig target,
    SshConnectionLog log,
  ) {
    final l10n = _localizations;
    final available = <String, ServerConfig>{
      for (final server in _backups.catalog?.servers ?? const <ServerConfig>[])
        server.id: server,
    };
    final route = <String, ServerConfig>{};
    final visited = <String>{target.id};
    var current = target;

    while (current.jumpHostId != null) {
      final jumpHostId = current.jumpHostId!;
      if (!visited.add(jumpHostId)) {
        throw SshConnectException(
          l10n.serverEditorJumpRouteCycle(jumpHostId),
          _JumpRouteFailure.cycle,
          log,
        );
      }
      if (route.length >= _maximumJumpHosts) {
        throw SshConnectException(
          l10n.serverEditorJumpRouteTooLong(_maximumJumpHosts),
          _JumpRouteFailure.overlong,
          log,
        );
      }

      final jumpHost = available[jumpHostId];
      if (jumpHost == null) {
        throw SshConnectException(
          l10n.serverEditorJumpHostMissing(jumpHostId),
          _JumpRouteFailure.missing,
          log,
        );
      }

      route[jumpHostId] = jumpHost;
      current = jumpHost;
    }

    return Map.unmodifiable(route);
  }

  AppLocalizations get _localizations {
    final context = _navigatorKey.currentContext;
    if (context != null) return AppLocalizations.of(context);

    return lookupAppLocalizations(AppLocalizations.supportedLocales.first);
  }

  /// The trial's host-key prompt: the same dialog a real connect raises,
  /// answered on the root navigator so it works while the editor is open.
  /// Returning false declines — the trial fails honestly rather than
  /// granting trust.
  Future<bool> _promptForHostKey(HostKeyDecision decision) async {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    final presented = decision.presented;
    return showHostKeyDialog(
      context,
      HostKeyPromptData(
        host: presented.host,
        port: presented.port,
        keyType: presented.type,
        fingerprintSha256: presented.fingerprintSha256,
        pinnedFingerprintSha256: decision.pinned?.fingerprintSha256,
      ),
    );
  }

  /// A keyboard-interactive challenge during the trial — the same dialog a
  /// real connect raises; an empty answer list cancels.
  Future<List<String>> _promptKeyboardInteractive(
    KeyboardInteractiveChallenge challenge,
  ) async {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return const <String>[];
    return showKeyboardInteractiveDialog(
      context,
      KeyboardInteractivePromptData(
        host: challenge.server.host,
        port: challenge.server.port,
        username: challenge.server.username,
        name: challenge.name,
        instruction: challenge.instruction,
        prompts: challenge.prompts,
      ),
    );
  }
}

/// The editor's storage behind [CredentialResolver]: the resolving vault,
/// and referenced keys read by path through the audited reader (Poltergeist
/// is not sandboxed, so there is no identity bookmark to honour).
final class _EditorCredentialSource implements CredentialSource {
  const _EditorCredentialSource(this._vault, this._identityReader);

  final SecretVault _vault;
  final IdentityFileReader _identityReader;

  @override
  Future<Secret?> storedSecret(String secretRef) => _vault.getSecret(secretRef);

  /// The resolver calls this only when [ServerConfig.identityFilePath] is set.
  @override
  Future<String> identityFile(ServerConfig config, CredentialDraft? draft) =>
      _identityReader.read(
        serverId: config.id,
        serverLabel: '${config.username}@${config.host}',
        identityFilePath: config.identityFilePath!,
      );
}
