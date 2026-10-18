import '../engine/protocol.dart';

/// The most servers FL-21's monitor set holds on one device (03 §4.3
/// step 4) [E]. The engine refuses a [SetMonitorSet] naming more, and the
/// app's toggles stop there.
const int kMonitorSetLimit = 10;

/// The engine's own subscription id for a monitored server's `overview`
/// (D45). The app's ids name its surfaces, and it never uses this one.
const String monitorSubscriptionId = 'engine:monitorSet';

/// Whether a fleet server may join the monitor set (FL-21, 03 §4.5's
/// background rule): background sampling dials it unattended, which never
/// prompts, so only a server that signs in without the user and whose
/// endpoint this device confirmed may join.
enum MonitorEligibility {
  eligible,

  /// A synced server whose endpoint this device has not confirmed, or
  /// whose endpoint changed since (03 §4.7, SAF-09). Imports count as
  /// confirmed on the device that imported them.
  endpointNotConfirmed,

  /// It signs in with a password or a key held in the vault, which asks
  /// the user while the vault does not exist (F3b).
  interactiveCredentials,

  /// An import from an older import store, whose credentials and route
  /// the engine does not know until the ssh_config is imported again (03
  /// §4.10).
  credentialsUnknown,
}

/// Whether [entry] may join the monitor set; one rule for the engine,
/// which enforces it, and the app, which offers only what it allows.
MonitorEligibility monitorEligibilityOf(FleetEntry entry) {
  if (entry.endpoint case final endpoint?
      when endpoint != EndpointConfirmation.confirmed) {
    return MonitorEligibility.endpointNotConfirmed;
  }

  return switch (entry.authKind) {
    null => MonitorEligibility.credentialsUnknown,
    FleetAuthKind.agent ||
    FleetAuthKind.identityFile => MonitorEligibility.eligible,
    FleetAuthKind.password ||
    FleetAuthKind.storedKey => MonitorEligibility.interactiveCredentials,
  };
}
