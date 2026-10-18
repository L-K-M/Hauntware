import '../catalog/host_key_mutations.dart';
import '../catalog/pin_verdicts.dart';
import '../catalog/record_coordinator.dart' show HostKeyConflict;

/// How a pulled-pin conflict was settled.
enum PulledPinResolution {
  /// The user's choice is in effect.
  resolved,

  /// The local pin changed after the conflict was shown, so the choice no
  /// longer describes it and nothing was done. The next sync round shows
  /// the conflict as it is now, if there still is one.
  stale,
}

/// Settles a [HostKeyConflict] that [SyncCoordinator.pinConflicts] raised
/// (catalog-library.md §7), as [RecordCoordinator.keepLocalPin] and
/// [RecordCoordinator.acceptPulledPin] do for Poltergeist. Séance's mirror
/// lives one round, so the next round re-derives what is left.
final class PulledPinResolver {
  PulledPinResolver({
    required this._hostKeys,
    required this._verdicts,
    HostKeyMutationGate? gate,
  }) : _gate = gate ?? HostKeyMutationGate();

  final ConflictAwareHostKeyStore _hostKeys;
  final PinVerdictStore _verdicts;
  final HostKeyMutationGate _gate;

  /// Keeps this device's pin and records the pulled fingerprint as
  /// rejected, so the same key returning is not raised again while a
  /// different one still is.
  Future<PulledPinResolution> keepLocal(HostKeyConflict conflict) =>
      _gate.run(() async {
        _checkLocators(conflict);
        final kept = await _hostKeys.replaceIfCurrent(
          conflict.local,
          conflict.local,
        );
        if (kept == HostKeyInstallResult.conflict) {
          return PulledPinResolution.stale;
        }

        await _verdicts.recordKeptVerdict(
          conflict.locator,
          conflict.pulled.fingerprintSha256,
        );
        return PulledPinResolution.resolved;
      });

  /// Trusts the pulled key in place of this device's pin. Accepting is
  /// explicit re-trust, so it also lifts a negative pin on the address.
  Future<PulledPinResolution> acceptPulled(HostKeyConflict conflict) =>
      _gate.run(() async {
        _checkLocators(conflict);
        final accepted = await _hostKeys.replaceIfCurrent(
          conflict.local,
          conflict.pulled,
        );
        if (accepted == HostKeyInstallResult.conflict) {
          return PulledPinResolution.stale;
        }

        await _verdicts.removeNegativePin(conflict.locator);
        return PulledPinResolution.resolved;
      });

  void _checkLocators(HostKeyConflict conflict) {
    if (conflict.local.locator != conflict.locator ||
        conflict.pulled.locator != conflict.locator) {
      throw ArgumentError.value(
        conflict.locator,
        'conflict',
        'local and pulled pins must use the conflict locator',
      );
    }
  }
}
