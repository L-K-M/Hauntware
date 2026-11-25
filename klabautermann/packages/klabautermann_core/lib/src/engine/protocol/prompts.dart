import 'package:meta/meta.dart';

/// The 03 §10.1 prompt kinds, in the table's own order.
enum PromptKind {
  hostKey,
  keyboardInteractive,
  credential,
  keyPassphrase,
  elevation,
}

/// What a [Prompt] asks; one variant per [PromptKind].
@immutable
sealed class PromptRequest {
  const PromptRequest();

  PromptKind get kind;
}

/// Trust a host key the pin store has never seen, or re-pin a changed one
/// (03 §4.6). A key that differs from the pinned one blocks the link with
/// [LinkBlockedReason.hostKeyChanged]; only the user's next [Connect] to
/// the blocked server asks about it, with the pinned key in
/// [pinnedFingerprintSha256] and [pinnedKeyType] (D61). Trusting it
/// replaces the pin. An unattended connect never asks.
final class HostKeyPromptRequest extends PromptRequest {
  const HostKeyPromptRequest({
    required this.keyType,
    required this.fingerprintSha256,
    this.pinnedFingerprintSha256,
    this.pinnedKeyType,
  });

  /// The presented key's algorithm, such as `ssh-ed25519`.
  final String keyType;

  /// The presented key's fingerprint in OpenSSH's `SHA256:` form.
  final String fingerprintSha256;

  /// The pinned key's fingerprint in the same form when the presented key
  /// differs from it, or null for a first-seen key.
  final String? pinnedFingerprintSha256;

  /// The pinned key's algorithm beside [pinnedFingerprintSha256]; it can
  /// differ from [keyType] when the server changed key algorithm.
  final String? pinnedKeyType;

  @override
  PromptKind get kind => PromptKind.hostKey;
}

/// The server's keyboard-interactive challenge (RFC 4256), shown as the
/// server sent it. It carries no echo flags (`seance_core`'s
/// `KeyboardInteractiveChallenge` has none), so a surface masks every
/// answer. [PromptResponsesAnswer] answers [questions] in order, and
/// [PromptCancelAnswer] declines them.
final class KeyboardInteractivePromptRequest extends PromptRequest {
  const KeyboardInteractivePromptRequest({
    this.user,
    this.name = '',
    this.instruction = '',
    this.questions = const [],
  });

  /// The account the engine signs in as on the asking machine; null
  /// where it does not say.
  final String? user;

  final String name;
  final String instruction;
  final List<String> questions;

  @override
  PromptKind get kind => PromptKind.keyboardInteractive;
}

/// The login password for [user] (03 §4.5): asked on a connect the user
/// started, for a server whose password the vault does not hold.
final class CredentialPromptRequest extends PromptRequest {
  const CredentialPromptRequest({
    required this.user,
    this.retry = false,
    this.canSave = false,
  });

  final String user;

  /// Whether the server refused the previous answer to this question.
  final bool retry;

  /// Whether the answer can be kept in the vault ([PromptSecretAnswer.save]):
  /// the server names a vault entry and the engine may write the vault.
  final bool canSave;

  @override
  PromptKind get kind => PromptKind.credential;
}

/// The passphrase of the encrypted private key [user] signs in with on the
/// asking machine, the server or one of its jump hosts (03 §4.5, D70):
/// asked on a connect the user started, when no passphrase the engine has
/// for this attempt opens the key. The answer opens the key for this
/// attempt only and is never kept: no vault entry, no keystore, and
/// nothing after the attempt ends, so the next connect asks again.
final class KeyPassphrasePromptRequest extends PromptRequest {
  const KeyPassphrasePromptRequest({
    required this.user,
    this.keyPath,
    this.retry = false,
  });

  final String user;

  /// The key file as the server's config names it, such as
  /// `~/.ssh/id_ed25519` (not expanded), or null for a key the vault holds.
  final String? keyPath;

  /// Whether the previous answer to this question did not open the key.
  final bool retry;

  @override
  PromptKind get kind => PromptKind.keyPassphrase;
}

/// The sudo password of [user] for admin mode (03 §8.2, D41).
final class ElevationPromptRequest extends PromptRequest {
  const ElevationPromptRequest({required this.user, this.retry = false});

  final String user;

  /// Whether sudo refused the previous answer.
  final bool retry;

  @override
  PromptKind get kind => PromptKind.elevation;
}

/// Why the engine withdrew a [Prompt].
enum PromptWithdrawnReason {
  /// Nobody answered before the prompt's deadline.
  expired,

  /// What asked ended first: the connect attempt or operation stopped.
  attemptEnded,
}

/// The answer to a [Prompt]; one variant per [PromptKind] (03 §10.1).
@immutable
sealed class PromptAnswer {
  const PromptAnswer();
}

/// The host-key decision for [PromptKind.hostKey].
final class PromptTrustAnswer extends PromptAnswer {
  const PromptTrustAnswer(this.accepted);

  /// Trust and record the presented key when true.
  final bool accepted;
}

/// One secret for [PromptKind.credential], [PromptKind.keyPassphrase] and
/// [PromptKind.elevation]; null dismisses the prompt without answering.
final class PromptSecretAnswer extends PromptAnswer {
  const PromptSecretAnswer(this.secret, {this.save = false});

  final String? secret;

  /// Keep [secret] in the vault once the server accepts it; honoured only
  /// for a [CredentialPromptRequest] whose `canSave` is set, never for a
  /// key passphrase.
  final bool save;
}

/// The ordered responses for [PromptKind.keyboardInteractive].
final class PromptResponsesAnswer extends PromptAnswer {
  const PromptResponsesAnswer(this.responses);

  final List<String> responses;
}

/// The user declined [PromptKind.keyboardInteractive]'s questions. The
/// engine sends the server no responses, so the attempt fails with
/// [LinkFailureKind.keyboardInteractiveCancelled] at once rather than
/// when the prompt expires. Only that kind takes it: a host key is
/// declined with `PromptTrustAnswer(false)`, a password or passphrase
/// prompt dismissed with `PromptSecretAnswer(null)`.
final class PromptCancelAnswer extends PromptAnswer {
  const PromptCancelAnswer();
}
