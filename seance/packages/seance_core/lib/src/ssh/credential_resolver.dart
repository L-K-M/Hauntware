import 'package:seance_protocol/seance_protocol.dart';

import 'ssh_session.dart';

/// The stored material a [CredentialResolver] reads. Each app supplies its
/// own: the vault read, and the referenced-key read together with whatever
/// locking, sandbox grants and identity auditing that app owns. Neither
/// method is called for agent auth or when a typed draft makes the read
/// unnecessary.
abstract interface class CredentialSource {
  /// The vault entry [secretRef] names, or null when this device has none.
  Future<Secret?> storedSecret(String secretRef);

  /// The PEM of [config]'s referenced key file. Called only when
  /// [ServerConfig.identityFilePath] is set; [draft] is passed through so the
  /// source can honour [CredentialDraft.identityBookmark].
  Future<String> identityFile(ServerConfig config, CredentialDraft? draft);
}

/// Credential material a server editor holds before saving, so a connection
/// test uses what was typed rather than what is stored. Without explicit
/// actions, a null or empty field means "not typed" and keeps the legacy
/// fallback rules. Explicit actions make keep, replace, and clear
/// unambiguous. Each field is read only under its own auth method.
final class CredentialDraft {
  const CredentialDraft({
    this.password,
    this.privateKeyPem,
    this.keyPassphrase,
    this.identityBookmark,
    this.credentialAction,
    this.passphraseAction,
  });

  final String? password;
  final String? privateKeyPem;
  final String? keyPassphrase;

  /// Explicit editor intent. Null preserves the legacy blank-field rules for
  /// callers that have not adopted keep/replace/clear yet.
  final CredentialEditAction? credentialAction;
  final KeyPassphraseAction? passphraseAction;

  /// A host-specific grant for the referenced key file (Séance's macOS
  /// security-scoped bookmark). Opaque here: the resolver checks only its
  /// presence and forwards it to [CredentialSource.identityFile].
  final Object? identityBookmark;
}

/// What resolving does when a server names a vault entry this device lacks.
enum MissingSecretPolicy {
  /// Throw [CredentialMissingException]. The default.
  fail,

  /// Resolve an empty password or key instead, as Poltergeist's editor path
  /// does today. An explicit switch so that divergence stays visible until
  /// Poltergeist adopts [fail].
  substituteEmpty,
}

/// A server names a vault entry this device does not have: its config was
/// saved on another device, which kept the password or key local. Connecting
/// with an empty credential instead would only fail later with a misleading
/// authentication error, so resolving refuses up front (CRED-05).
final class CredentialMissingException implements Exception {
  const CredentialMissingException({
    required this.serverId,
    required this.serverLabel,
    required this.authMethod,
  });

  /// The server whose credential is missing: the one connecting, or a jump
  /// host on its path.
  final String serverId;
  final String serverLabel;
  final AuthMethod authMethod;

  @override
  String toString() {
    final what = authMethod == AuthMethod.privateKey
        ? 'private key'
        : 'password';
    return 'Credential required on this device: the $what for '
        '"$serverLabel" was saved on another device and is not here. Enter '
        'it on this device, or switch the server to the SSH agent.';
  }
}

/// Turns a [ServerConfig] plus optional editor drafts into the
/// [SshCredentials] a connection authenticates with. The decision table
/// (agent short-circuit, per-method draft precedence, the orphan-bookmark
/// guard, vault reads by `secretRef`) lives here once; storage access goes
/// through the app's [CredentialSource].
final class CredentialResolver {
  CredentialResolver(
    this._source, {
    this.missingSecretPolicy = MissingSecretPolicy.fail,
  });

  final CredentialSource _source;

  /// Applies where a stored password or stored key is the credential. The
  /// optional passphrase entry beside a referenced key file is not subject to
  /// it: an absent entry there means no passphrase under either policy.
  final MissingSecretPolicy missingSecretPolicy;

  /// Resolves [config]'s credential from an explicit draft action when one is
  /// present, otherwise with the legacy typed-field precedence. A configured
  /// [ServerConfig.identityFilePath] wins over a draft PEM.
  ///
  /// Throws [ArgumentError] for an identity bookmark under key auth with
  /// neither a path nor a typed PEM, and [CredentialMissingException] under
  /// [MissingSecretPolicy.fail] for a named vault entry this device lacks.
  Future<SshCredentials> resolve(
    ServerConfig config, {
    CredentialDraft? draft,
  }) async {
    String? typed(String? value) =>
        (value == null || value.isEmpty) ? null : value;
    if (config.authMethod == AuthMethod.agent) {
      return const SshCredentials.agent();
    }

    // A cross-file contract with the editor, which builds the grant from the
    // path it is about (Séance's `_bookmarkFor` returns null without one).
    // Without the path this branch never runs, so a bookmark passed alone
    // would be silently dropped and the test would resolve the vault
    // credential instead — a green result for a key nobody asked it to try.
    // A throw, not an assert: stripped from the build users run, the only
    // symptom of a caller getting this wrong is a green "authenticated" for a
    // credential nobody asked to test — the same reason the exclusion guard in
    // `ServerConfig.copyWith` throws.
    // Only under key auth: for a password or the agent the bookmark is never
    // consulted, so a stale one left over from an auth-method switch cannot
    // change what is tested, and throwing would turn a harmless leftover
    // into a failed test. A typed PEM is the same case under key auth: it is
    // returned before anything consults a path or a grant.
    // The name stays `draftIdentityBookmark`, the editor-facing parameter it
    // has always carried, so callers matching on it keep working.
    final bookmark = draft?.identityBookmark;
    if (config.authMethod == AuthMethod.privateKey &&
        config.identityFilePath == null &&
        typed(draft?.privateKeyPem) == null &&
        bookmark != null) {
      throw ArgumentError.value(
        bookmark,
        'draftIdentityBookmark',
        'only honoured alongside identityFilePath: without the path the '
            'grant is dropped and the vault credential is tested instead',
      );
    }
    if (draft?.credentialAction != null) {
      return _resolveExplicit(config, draft!);
    }
    switch (config.authMethod) {
      case AuthMethod.agent:
        return const SshCredentials.agent();
      case AuthMethod.password:
        final password = typed(draft?.password);
        if (password != null) return SshCredentials.password(password);
        final secret = await _savedSecret(config);
        return SshCredentials.password(secret?.value ?? '');
      case AuthMethod.privateKey:
        // "Reference, don't store": read the key from disk at connect time.
        if (config.identityFilePath != null) {
          final pem = await _source.identityFile(config, draft);
          final typedPassphrase = typed(draft?.keyPassphrase);
          final stored = typedPassphrase != null || config.secretRef == null
              ? null
              : await _source.storedSecret(config.secretRef!);
          return SshCredentials.privateKey(
            pem,
            // A typed passphrase needs no stored-passphrase read or unlock.
            keyPassphrase:
                typedPassphrase ??
                _identityFilePassphrase(stored, config.identityFilePath!),
          );
        }
        final typedPem = typed(draft?.privateKeyPem);
        if (typedPem != null) {
          return SshCredentials.privateKey(
            typedPem,
            keyPassphrase: typed(draft?.keyPassphrase),
          );
        }
        final secret = await _savedSecret(config);
        return SshCredentials.privateKey(
          secret?.value ?? '',
          keyPassphrase: typed(draft?.keyPassphrase) ?? secret?.keyPassphrase,
        );
    }
  }

  Future<SshCredentials> _resolveExplicit(
    ServerConfig config,
    CredentialDraft draft,
  ) async {
    String? typed(String? value) =>
        (value == null || value.isEmpty) ? null : value;
    final action = draft.credentialAction!;
    switch (config.authMethod) {
      case AuthMethod.agent:
        return const SshCredentials.agent();
      case AuthMethod.password:
        switch (action) {
          case CredentialEditAction.clear:
            return const SshCredentials.password('');
          case CredentialEditAction.replace:
            final password = typed(draft.password);
            if (password == null) {
              throw ArgumentError.value(
                draft.password,
                'draft.password',
                'must not be empty when replacing a password',
              );
            }
            return SshCredentials.password(password);
          case CredentialEditAction.keep:
            final secret = await _savedSecret(config);
            _requireKind(secret, SecretKind.password, config);
            return SshCredentials.password(secret?.value ?? '');
        }
      case AuthMethod.privateKey:
        final path = config.identityFilePath;
        if (path != null) {
          final pem = await _source.identityFile(config, draft);
          if (action == CredentialEditAction.clear) {
            return SshCredentials.privateKey(pem);
          }
          Secret? stored;
          final passphraseAction = draft.passphraseAction;
          if (action == CredentialEditAction.keep ||
              passphraseAction == KeyPassphraseAction.keep) {
            stored = await _savedSecret(config);
            _requireKind(stored, SecretKind.privateKey, config);
          }
          final passphrase = switch (action) {
            CredentialEditAction.keep => _identityFilePassphrase(stored, path),
            CredentialEditAction.replace => switch (passphraseAction) {
              KeyPassphraseAction.keep => _identityFilePassphrase(stored, path),
              KeyPassphraseAction.replace =>
                typed(draft.keyPassphrase) ??
                    (throw ArgumentError.value(
                      draft.keyPassphrase,
                      'draft.keyPassphrase',
                      'must not be empty when replacing a passphrase',
                    )),
              KeyPassphraseAction.clear => null,
              null => throw ArgumentError(
                'passphraseAction is required for an explicit key edit',
              ),
            },
            CredentialEditAction.clear => null,
          };
          return SshCredentials.privateKey(pem, keyPassphrase: passphrase);
        }

        if (action == CredentialEditAction.clear) {
          return const SshCredentials.privateKey('');
        }
        if (action == CredentialEditAction.keep) {
          final secret = await _savedSecret(config);
          _requireKind(secret, SecretKind.privateKey, config);
          if (secret != null && secret.value.isEmpty) {
            throw ArgumentError('There is no saved pasted private key to keep');
          }
          return SshCredentials.privateKey(
            secret?.value ?? '',
            keyPassphrase: secret?.keyPassphrase,
          );
        }

        final pem = typed(draft.privateKeyPem);
        if (pem == null) {
          throw ArgumentError.value(
            draft.privateKeyPem,
            'draft.privateKeyPem',
            'must not be empty when replacing a private key',
          );
        }
        final passphraseAction = draft.passphraseAction;
        final String? passphrase;
        switch (passphraseAction) {
          case KeyPassphraseAction.keep:
            final secret = await _savedSecret(config);
            _requireKind(secret, SecretKind.privateKey, config);
            if (secret?.value != pem) {
              throw ArgumentError(
                'A passphrase can be kept only when the pasted key is '
                'unchanged',
              );
            }
            passphrase = secret?.keyPassphrase;
          case KeyPassphraseAction.replace:
            passphrase = typed(draft.keyPassphrase);
            if (passphrase == null) {
              throw ArgumentError.value(
                draft.keyPassphrase,
                'draft.keyPassphrase',
                'must not be empty when replacing a passphrase',
              );
            }
          case KeyPassphraseAction.clear:
            passphrase = null;
          case null:
            throw ArgumentError(
              'passphraseAction is required for an explicit key edit',
            );
        }
        return SshCredentials.privateKey(pem, keyPassphrase: passphrase);
    }
  }

  static String? _identityFilePassphrase(Secret? secret, String path) {
    if (secret == null) return null;
    final legacy =
        secret.identityFilePath == null &&
        secret.identityFilePassphrase == null;
    if (legacy) return secret.keyPassphrase;
    if (secret.identityFilePath != path) {
      throw ArgumentError(
        'The saved passphrase belongs to a different identity file',
      );
    }
    return secret.identityFilePassphrase;
  }

  static void _requireKind(
    Secret? secret,
    SecretKind expected,
    ServerConfig config,
  ) {
    if (secret == null || secret.kind == expected) return;
    throw ArgumentError(
      'The saved ${secret.kind.name} credential for ${config.id} cannot be '
      'used as ${expected.name}',
    );
  }

  /// An [SshJumpHostResolver] that looks a saved hop up with [lookup] and
  /// resolves its stored credential (no drafts). An unknown id yields null.
  SshJumpHostResolver jumpHostResolver(
    Future<ServerConfig?> Function(String id) lookup,
  ) => (id) async {
    final config = await lookup(id);
    if (config == null) return null;

    return ResolvedSshHost(config, await resolve(config));
  };

  /// The vault entry [config] names, or null when it names none. A named
  /// entry this device does not have follows [missingSecretPolicy].
  Future<Secret?> _savedSecret(ServerConfig config) async {
    final ref = config.secretRef;
    if (ref == null) return null;

    final secret = await _source.storedSecret(ref);
    if (secret != null) return secret;
    return switch (missingSecretPolicy) {
      MissingSecretPolicy.substituteEmpty => null,
      MissingSecretPolicy.fail => throw CredentialMissingException(
        serverId: config.id,
        serverLabel: config.label,
        authMethod: config.authMethod,
      ),
    };
  }
}
