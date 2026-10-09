// Ported from Séance app/seance_app/lib/services/server_duplication.dart @
// 035b0d8 (tag v0.9.1), plus `duplicationSourceUnchanged` and
// `SourceServerChanged` from app_state.dart (kept beside the planner they
// guard rather than in a state class this port does not carry); see
// docs/PORTS.md.
// Divergence: `IdentityFileBookmark`/`bookmarkFor` dropped — Poltergeist's
// macOS build is not sandboxed, so a referenced key file opens by path and
// there is no security-scoped grant to carry into the copy.
// The copy label and the config copy themselves come from
// seance_protocol, shared with Séance.
import 'package:poltergeist_core/poltergeist_core.dart';

/// Whether the server a duplicate was planned from still is what it was.
///
/// Only the credential reference matters: the copy carries its own id, label
/// and timestamps, and a rename or a colour change on the source between the
/// plan and the save costs nothing. A missing server or a different ref does,
/// because the credential the plan holds was read against the old one.
bool duplicationSourceUnchanged(ServerConfig? latest, ServerConfig source) =>
    latest != null && latest.secretRef == source.secretRef;

/// The source of a duplicate stopped matching what the copy was planned from.
///
/// Its [toString] is a sentence because the catalog's toast shows it verbatim,
/// the way it shows a locked keyring: a user who is told only "could not
/// duplicate" has nothing to do next.
class SourceServerChanged implements Exception {
  final String label;
  const SourceServerChanged(this.label);

  @override
  String toString() => '"$label" changed while it was being copied — it was '
      'deleted, or it now holds a different credential. Nothing was created.';
}

/// A planned duplicate: the config to store and the vault entry to write
/// first when the source had a credential to copy.
class ServerDuplication {
  final ServerConfig config;
  final Secret? secret;

  const ServerDuplication({required this.config, this.secret});
}

/// Work out what duplicating [source] takes, without writing anything.
///
/// Separated from the service that saves it because this is the part that can
/// lose a credential, and orchestration left inside a service is
/// orchestration nothing can exercise. The ids and the clock are arguments
/// for the same reason.
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
  );
}
