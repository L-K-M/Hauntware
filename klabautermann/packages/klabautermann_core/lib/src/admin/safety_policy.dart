// The engine's enforcement of the app's safety preferences (M4 plan M4):
// observe-only and read-only servers get no plan and no admin mode, in the
// engine itself and not only hidden in the UI (SAF-01, SAF-06).
import '../engine/protocol.dart';

/// Why [policy] forbids changing [serverId], or null when it allows it:
/// read-only (global or the server's) first, then observe-only.
ActionRefusalReason? safetyRefusal(SafetyPolicy policy, String serverId) {
  final server = policy.servers[serverId] ?? const ServerSafety();
  if (policy.globalReadOnly || server.readOnly) {
    return ActionRefusalReason.readOnly;
  }
  if (!server.management) return ActionRefusalReason.observeOnly;
  return null;
}

/// The same refusal as admin mode words it.
AdminFailure? adminRefusal(SafetyPolicy policy, String serverId) =>
    switch (safetyRefusal(policy, serverId)) {
      ActionRefusalReason.readOnly => AdminFailure.readOnly,
      ActionRefusalReason.observeOnly => AdminFailure.observeOnly,
      _ => null,
    };

/// Why [policy] is not one the engine takes, or null: its expiry must be
/// one of the Safety tab's choices.
String? validateSafetyPolicy(SafetyPolicy policy) =>
    kAdminExpiryChoices.contains(policy.adminExpiry)
    ? null
    : 'admin expiry ${policy.adminExpiry.inMinutes} min is not offered';
