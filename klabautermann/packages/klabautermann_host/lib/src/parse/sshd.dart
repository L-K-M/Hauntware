/// The parser for SEC-01's sshd posture (03 §7.10), as
/// [HostCommands.sshdPosture] prints it: `sshd -T`'s lowercase
/// `keyword value` lines.
library;

import 'package:meta/meta.dart';

import '../commands/commands.dart' show HostCommands, kSshdMarker;

/// How much of the connection the read's `-C` named, and so which `Match`
/// blocks the configuration reflects.
enum SshdMatchContext {
  /// The user, the client's address and the local address and port: every
  /// `Match` block that applies to this connection.
  connection,

  /// The user and the client's address, as sshd before 7.x accepts:
  /// `Match LocalAddress` and `Match LocalPort` blocks are not applied.
  remote,

  /// No `-C`: no `Match` block is applied.
  none,
}

/// An sshd setting that keeps the Docker transport's socket forwarding
/// (`direct-streamlocal`, 03 §5.3) from opening.
enum SshdForwardingBlock {
  /// `AllowStreamLocalForwarding no` or `remote`.
  allowStreamLocalForwarding('AllowStreamLocalForwarding'),

  /// `AllowTcpForwarding no` or `remote`: sshd applies its local TCP
  /// forwarding permissions to socket paths too.
  allowTcpForwarding('AllowTcpForwarding'),

  /// A `PermitOpen` without `any` or `*:*`, which no socket path can
  /// match.
  permitOpen('PermitOpen'),

  /// `DisableForwarding yes`.
  disableForwarding('DisableForwarding');

  const SshdForwardingBlock(this.keyword);

  /// The setting's name as sshd_config spells it.
  final String keyword;
}

/// `PermitRootLogin`.
enum SshdRootLogin {
  yes,
  no,

  /// `prohibit-password`, `without-password` before OpenSSH 7.0.
  keysOnly,
  forcedCommandsOnly;

  static SshdRootLogin? of(String? value) => switch (value) {
    'yes' => yes,
    'no' => no,
    'prohibit-password' || 'without-password' => keysOnly,
    'forced-commands-only' => forcedCommandsOnly,
    _ => null,
  };
}

/// `AllowTcpForwarding` or `AllowStreamLocalForwarding`: which directions
/// may forward.
enum SshdForwarding {
  /// `yes` or `all`.
  all,
  local,
  remote,
  no;

  static SshdForwarding? of(String? value) => switch (value) {
    'yes' || 'all' => all,
    'local' => local,
    'remote' => remote,
    'no' => no,
    _ => null,
  };

  bool get allowsLocal => this == all || this == local;
}

/// The effective sshd configuration for one connection (SEC-01). A
/// setting sshd did not print, or printed with a value this reader does
/// not know, is null; sshd prints every setting it knows, so null means
/// an sshd too old or too new for it.
@immutable
final class SshdPosture {
  SshdPosture({
    required this.match,
    Iterable<int> ports = const [],
    Iterable<String> listenAddresses = const [],
    this.permitRootLogin,
    this.passwordAuthentication,
    this.keyboardInteractive,
    this.pubkeyAuthentication,
    this.authenticationMethods,
    Iterable<String> hostKeyTypes = const [],
    Iterable<String> userKeyTypes = const [],
    this.maxSessions,
    this.allowTcpForwarding,
    this.allowStreamLocalForwarding,
    this.permitOpen,
    this.disableForwarding,
  }) : ports = List.unmodifiable(ports),
       listenAddresses = List.unmodifiable(listenAddresses),
       hostKeyTypes = List.unmodifiable(hostKeyTypes),
       userKeyTypes = List.unmodifiable(userKeyTypes);

  final SshdMatchContext match;
  final List<int> ports;

  /// `ListenAddress` as sshd prints it, `0.0.0.0:22` or `[::]:22`.
  final List<String> listenAddresses;

  final SshdRootLogin? permitRootLogin;

  final bool? passwordAuthentication;

  /// `KbdInteractiveAuthentication`, or `ChallengeResponseAuthentication`
  /// before OpenSSH 8.7.
  final bool? keyboardInteractive;

  final bool? pubkeyAuthentication;

  /// `AuthenticationMethods`, or null for its default `any`.
  final String? authenticationMethods;

  /// The host keys' types, from their file names: `ed25519`, `ecdsa`,
  /// `rsa`; a key file named otherwise is listed by its path.
  final List<String> hostKeyTypes;

  /// `PubkeyAcceptedAlgorithms` (`PubkeyAcceptedKeyTypes` before 8.5):
  /// the user key types sshd accepts.
  final List<String> userKeyTypes;

  final int? maxSessions;

  final SshdForwarding? allowTcpForwarding;
  final SshdForwarding? allowStreamLocalForwarding;

  /// `any`, `none` or the `host:port` pairs allowed. sshd checks a
  /// socket path against the same list (`channel_connect_to_path`), and
  /// only `any` or a `*:*` pair matches one.
  final String? permitOpen;
  final bool? disableForwarding;

  /// The settings that block the Docker transport; one sshd did not print
  /// blocks nothing. Empty does not mean it opens: an
  /// `authorized_keys` option can still refuse it, and `sshd -T` does
  /// not show those.
  Set<SshdForwardingBlock> get dockerBlocks => {
    if (!(allowStreamLocalForwarding?.allowsLocal ?? true))
      SshdForwardingBlock.allowStreamLocalForwarding,
    if (!(allowTcpForwarding?.allowsLocal ?? true))
      SshdForwardingBlock.allowTcpForwarding,
    if (permitOpen case final open?
        when !open.split(' ').any((pair) => pair == 'any' || pair == '*:*'))
      SshdForwardingBlock.permitOpen,
    if (disableForwarding ?? false) SshdForwardingBlock.disableForwarding,
  };
}

/// What [HostCommands.sshdPosture] found.
@immutable
sealed class SshdRead {
  const SshdRead();
}

/// No sshd binary on root's PATH or in the usual places.
final class SshdMissing extends SshdRead {
  const SshdMissing();
}

/// `sshd -T` refused even without `-C`, as for a configuration error.
final class SshdFailed extends SshdRead {
  const SshdFailed(this.detail);

  /// sshd's first lines of error output.
  final String detail;
}

/// The configuration sshd printed.
final class SshdConfig extends SshdRead {
  const SshdConfig(this.posture);

  final SshdPosture posture;
}

final _hostKeyName = RegExp(r'ssh_host_([a-z0-9]+)_key(?:\.pub)?$');

/// The read in [raw], or null when it is not the read's output.
SshdRead? parseSshdPosture(String raw) {
  final lines = raw.split('\n');
  final first = lines.first.trim();
  if (first == '$kSshdMarker missing') return const SshdMissing();
  if (first == '$kSshdMarker failed') {
    return SshdFailed(
      [
        for (final line in lines.skip(1))
          if (line.trim() case final text when text.isNotEmpty) text,
      ].join('\n'),
    );
  }

  final match = switch (first) {
    '$kSshdMarker full' => SshdMatchContext.connection,
    '$kSshdMarker basic' => SshdMatchContext.remote,
    '$kSshdMarker none' => SshdMatchContext.none,
    _ => null,
  };
  if (match == null) return null;

  final options = <String, List<String>>{};
  for (final line in lines.skip(1)) {
    final trimmed = line.trim();
    final space = trimmed.indexOf(' ');
    if (space <= 0) continue;
    final keyword = trimmed.substring(0, space);
    // sshd prints its keywords in lowercase; anything else is a warning
    // that slipped through.
    if (keyword != keyword.toLowerCase()) continue;
    (options[keyword] ??= []).add(trimmed.substring(space + 1).trim());
  }
  if (options.isEmpty) return null;

  String? one(String keyword) => options[keyword]?.first;
  bool? yesNo(String keyword) => switch (one(keyword)) {
    'yes' => true,
    'no' => false,
    _ => null,
  };
  List<String> list(String? value) => [
    for (final item in (value ?? '').split(','))
      if (item.isNotEmpty) item,
  ];

  return SshdConfig(
    SshdPosture(
      match: match,
      ports: [
        for (final port in options['port'] ?? const <String>[])
          ?int.tryParse(port),
      ],
      listenAddresses: options['listenaddress'] ?? const [],
      permitRootLogin: SshdRootLogin.of(one('permitrootlogin')),
      passwordAuthentication: yesNo('passwordauthentication'),
      keyboardInteractive:
          yesNo('kbdinteractiveauthentication') ??
          yesNo('challengeresponseauthentication'),
      pubkeyAuthentication: yesNo('pubkeyauthentication'),
      authenticationMethods: switch (one('authenticationmethods')) {
        null || 'any' => null,
        final methods => methods,
      },
      hostKeyTypes: {
        for (final path in options['hostkey'] ?? const <String>[])
          _hostKeyName.firstMatch(path)?[1] ?? path,
      },
      userKeyTypes: list(
        one('pubkeyacceptedalgorithms') ?? one('pubkeyacceptedkeytypes'),
      ),
      maxSessions: int.tryParse(one('maxsessions') ?? ''),
      allowTcpForwarding: SshdForwarding.of(one('allowtcpforwarding')),
      allowStreamLocalForwarding: SshdForwarding.of(
        one('allowstreamlocalforwarding'),
      ),
      permitOpen: one('permitopen'),
      disableForwarding: yesNo('disableforwarding'),
    ),
  );
}
