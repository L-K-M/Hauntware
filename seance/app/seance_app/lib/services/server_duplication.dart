import 'package:seance_core/seance_core.dart';

import 'app_settings.dart';

/// A planned duplicate: the config to store, the vault entry to write first
/// when the source had a credential to copy, and the security-scope grant to
/// file under the copy's id.
class ServerDuplication {
  final ServerConfig config;
  final Secret? secret;

  /// The source's grant for its identity file, to be stored under the copy's
  /// id. Carried through the plan rather than read at the save site so the
  /// one line this feature's doc calls load-bearing is reachable by a test:
  /// without it a duplicate of a Browse…-picked key falls back to the raw
  /// path and cannot open a key outside `~/.ssh`.
  final IdentityFileBookmark? identityFileBookmark;

  const ServerDuplication({
    required this.config,
    this.secret,
    this.identityFileBookmark,
  });
}

/// Work out what duplicating [source] takes, without writing anything.
///
/// Separated from the notifier that saves it because this is the part that can
/// lose a credential, and orchestration left inside an `AppState` is
/// orchestration nothing can exercise — no test in this app can build an
/// `AppServices`, whose constructor is private. The ids and the clock are
/// arguments for the same reason.
///
/// A dangling [ServerConfig.secretRef] — the config points at a vault entry
/// that is gone — plans as "no credential" rather than failing: the original
/// is already in that state, and the copy is not the place to discover it. A
/// vault that *throws*, which is what a locked OS keyring does, propagates
/// instead: a duplicate that quietly lost its password would look identical in
/// the list and only admit it at connect time.
Future<ServerDuplication> planServerDuplication(
  ServerConfig source, {
  required SecretVault vault,
  required Iterable<String> takenLabels,
  required String id,
  required String secretId,
  required int now,
  IdentityFileBookmark? Function(String serverId)? bookmarkFor,
}) async {
  Secret? secret;
  final sourceRef = source.secretRef;
  if (sourceRef != null) {
    final original = await vault.getSecret(sourceRef);
    // copyWith rather than a fresh constructor: listing the fields here would
    // silently drop anything Secret gains later, which is the same failure
    // duplicateServerConfig's JSON-compared test exists to catch for configs.
    if (original != null) secret = original.copyWith(id: secretId);
  }
  return ServerDuplication(
    config: duplicateServerConfig(
      source,
      id: id,
      label: duplicateServerLabel(source.label, takenLabels),
      secretRef: secret?.id,
      now: now,
    ),
    secret: secret,
    identityFileBookmark: bookmarkFor?.call(source.id),
  );
}
