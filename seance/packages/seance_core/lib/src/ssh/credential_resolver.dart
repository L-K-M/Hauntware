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
/// test uses what was typed rather than what is stored. A null or empty field
/// means "not typed"; see [CredentialResolver.resolve] for when that falls
/// back to storage (a blank passphrase beside a typed PEM means none) and
/// when a configured key file wins over a typed PEM. Each field is read only
/// under its own auth method.
final class CredentialDraft {
  const CredentialDraft({
    this.password,
    this.privateKeyPem,
    this.keyPassphrase,
    this.identityBookmark,
  });

  final String? password;
  final String? privateKeyPem;
  final String? keyPassphrase;

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

  /// Resolves [config]'s credential, preferring [draft] fields typed under
  /// the auth method in force. A configured [ServerConfig.identityFilePath]
  /// wins over a draft PEM, and a blank passphrase beside a typed PEM means
  /// "no passphrase" because a typed PEM is new key material.
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
          return SshCredentials.privateKey(
            pem,
            // A typed passphrase needs no stored-passphrase read or unlock.
            keyPassphrase:
                typed(draft?.keyPassphrase) ??
                (config.secretRef == null
                    ? null
                    : (await _source.storedSecret(
                        config.secretRef!,
                      ))?.keyPassphrase),
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
