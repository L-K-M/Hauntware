import 'package:meta/meta.dart';

import 'equality.dart' show sameItems;
import 'prompts.dart' show PromptKind;

/// Whether the user can see the app, as [SetAppActivity] reports it.
enum AppActivity {
  /// The user can see the app.
  foreground,

  /// The user cannot see the app, such as a phone app sent to the
  /// background.
  background,
}

/// A link's state behind [LinkState] (D46): the eight states of
/// `seance_core`'s `SshLinkState`, mirrored so that no `seance_core` type
/// crosses the boundary (03 §3.2), plus the engine's own [LinkBlocked].
/// Every reason is an enum the app words through its ARB catalog (D35).
/// Compares by value, because a status that crosses the boundary may
/// arrive as a copy.
@immutable
sealed class LinkStatus {
  const LinkStatus();

  /// The values that tell two statuses of one variant apart.
  List<Object?> get _values => const [];

  @override
  bool operator ==(Object other) =>
      other is LinkStatus &&
      other.runtimeType == runtimeType &&
      sameItems(other._values, _values);

  @override
  int get hashCode => Object.hash(runtimeType, Object.hashAll(_values));
}

/// No attempt has started. The app reads a server it has no status for as
/// idle.
final class LinkIdle extends LinkStatus {
  const LinkIdle();
}

/// Reaching the server, possibly through its jump hosts.
final class LinkConnecting extends LinkStatus {
  const LinkConnecting();
}

/// The transport is up; user authentication runs.
final class LinkAuthenticating extends LinkStatus {
  const LinkAuthenticating();
}

/// Authenticated and working. A learned session limit is [LinkDegraded];
/// what the host can do arrives with the sampling protocol, not here.
final class LinkReady extends LinkStatus {
  const LinkReady();
}

/// Working, but the server showed a limit below the engine's budget.
final class LinkDegraded extends LinkStatus {
  const LinkDegraded(this.reason);

  final LinkDegradedReason reason;

  @override
  List<Object?> get _values => [reason];
}

/// Waiting until [until] before the engine dials again (CN-05).
final class LinkBackoff extends LinkStatus {
  const LinkBackoff(this.until);

  final DateTime until;

  @override
  List<Object?> get _values => [until];
}

/// Waiting on the [Prompt] [promptId], which asks for [kind]; the prompt
/// itself arrives as its own event.
final class LinkNeedsUser extends LinkStatus {
  const LinkNeedsUser({required this.promptId, required this.kind});

  final String promptId;
  final PromptKind kind;

  @override
  List<Object?> get _values => [promptId, kind];
}

/// The engine does not dial until the user decides something outside the
/// connect flow (D46); no prompt can answer it.
final class LinkBlocked extends LinkStatus {
  const LinkBlocked(this.reason);

  final LinkBlockedReason reason;

  @override
  List<Object?> get _values => [reason];
}

/// The link ended. [reason] says how; [failure] says what the engine found
/// behind it, or null when nothing failed or the engine could not tell.
final class LinkClosed extends LinkStatus {
  const LinkClosed(this.reason, {this.failure});

  final LinkClosedReason reason;
  final LinkFailureKind? failure;

  @override
  List<Object?> get _values => [reason, failure];
}

/// Why a link is [LinkDegraded] (`seance_core`'s `SshLinkDegradedReason`).
enum LinkDegradedReason {
  /// The server refused a session channel below the budget, so the link
  /// queues at the learned limit (03 §5.2's low-session mode).
  sessionLimitLearned,
}

/// Why a link is [LinkBlocked].
enum LinkBlockedReason {
  /// The server's endpoint no longer matches the one confirmed on this
  /// device (D16, 03 §4.7).
  endpointChanged,

  /// The server presented a host key other than the pinned one (03 §4.6).
  hostKeyChanged,
}

/// How a link ended (`seance_core`'s `SshLinkClosedReason`).
enum LinkClosedReason {
  /// The engine closed the link on purpose, for example on [Disconnect].
  closedByOwner,

  /// The transport ended underneath the link.
  linkLost,

  /// The transport reported an error before it ended.
  transportError,

  /// A keepalive ping went unanswered past its deadline, or the samplers
  /// stayed silent after one missed a deadline (CN-06, 03 §6.4).
  pingTimeout,

  /// Connecting or authenticating never produced a transport.
  connectFailed,
}

/// What the engine found behind a [LinkClosed]. The first eight are the
/// connect failures protocol version 3 classifies (03 §10.1); the last
/// three are 03 §5.3's client limitations.
enum LinkFailureKind {
  /// The connection was refused, or the host had no route or no address,
  /// or its SSH service closed the connection before the handshake began.
  unreachable,

  /// Connecting or the handshake ran past its deadline.
  timedOut,

  /// The server refused every credential offered.
  authenticationRejected,

  /// No credential could be offered: the ssh-agent holds no keys, a key
  /// file could not be read or holds no key the client can use, or a
  /// stored secret is not on this device.
  credentialUnavailable,

  /// The private key is encrypted and the engine has no passphrase that
  /// opens it: an unattended connect, which never asks, or a connect whose
  /// [KeyPassphrasePromptRequest] the user dismissed or let expire.
  /// Nothing reached the server. The user's next connect asks for it.
  keyPassphraseRequired,

  /// Inside the Flatpak sandbox, a key file could not be found: the
  /// sandbox shows only the paths its manifest grants, so a key outside
  /// them reads as missing whether or not it exists (03 §4.5).
  keyFileHiddenBySandbox,

  /// The user, or the background rule, declined a first-seen host key.
  hostKeyDeclined,

  /// The user cancelled keyboard-interactive questions the server or one
  /// of its jump hosts asked ([PromptCancelAnswer]).
  keyboardInteractiveCancelled,

  /// The server requires an algorithm the client does not support yet
  /// (CN-23).
  unsupportedAlgorithm,

  /// The server offers only algorithms the suite refuses as insecure
  /// (D23).
  insecureAlgorithmsOnly,

  /// The key exchange did not finish before the server gave up (03 §5.3:
  /// finite-field Diffie-Hellman on Android).
  keyExchangeTimedOut,
}

/// A reachability probe's answer behind [Reachability] (`seance_core`'s
/// `ProbeStatus`).
enum ReachabilityStatus {
  /// The host accepted a TCP connection on its SSH port.
  online,

  /// The connection was refused, or the host had no route or no address.
  offline,

  /// The probe could not tell, for example after a timeout; not
  /// [offline], since a host behind a firewall or a jump host may be up.
  unknown,
}
