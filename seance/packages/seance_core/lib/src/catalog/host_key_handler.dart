/// The library's `hostkey:` handler (docs/design/catalog-library.md
/// sections 5.3 and 7): pulled pins apply through the conflict-aware store,
/// so a key that conflicts with the locally trusted pin is quarantined
/// unapplied and reported through the coordinator's re-derived diff, never
/// silently trusted.
library;

import 'package:seance_protocol/seance_protocol.dart';

import 'catalog_writer.dart';
import 'host_key_mutations.dart';
import 'pin_verdicts.dart';
import 'record_handler.dart';

/// Registered by every coordinator.
final class HostKeyHandler implements RecordHandler {
  HostKeyHandler({
    required ConflictAwareHostKeyStore hostKeys,
    required PinVerdictStore pinVerdicts,
    required HostKeyMutationGate hostKeyMutations,
  }) : // Collaborator names stay public; the fields stay private.
       // ignore: prefer_initializing_formals
       _hostKeys = hostKeys,
       // ignore: prefer_initializing_formals
       _pinVerdicts = pinVerdicts,
       // ignore: prefer_initializing_formals
       _hostKeyMutations = hostKeyMutations;

  static const String idPrefix = 'hostkey';

  /// A pin is public key material; the passphrase trial may open it.
  static const opensInTrial = true;

  final ConflictAwareHostKeyStore _hostKeys;
  final PinVerdictStore _pinVerdicts;
  final HostKeyMutationGate _hostKeyMutations;

  @override
  String? get prefix => idPrefix;

  @override
  ApplyPhase get phase => ApplyPhase.pins;

  @override
  RecordKind get kind => RecordKind.hostKey;

  @override
  bool get trialDecryptable => opensInTrial;

  @override
  Future<ApplyOutcome> applyLive(
    EncryptedRecord record,
    ApplyContext context,
  ) async {
    final dec = await context.open(record);
    if (dec == null) {
      return context.holdActive ? ApplyOutcome.deferred : ApplyOutcome.skipped;
    }
    if (dec.kind != RecordKind.hostKey) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    final HostKey pin;
    try {
      pin = HostKey.fromJson(dec.data);
    } catch (_) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    // A pin stores under its payload's locator: a record whose envelope id
    // names a different one would plant trust for an address nothing ever
    // named.
    if (record.id != pin.recordId) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    await context.tripwires.clear(record.id);
    return _hostKeyMutations.run(() async {
      // The gate makes the verdict and conditional store write one trust
      // decision relative to forget/re-trust actions.
      if ((await _pinVerdicts.negativePins()).contains(pin.locator)) {
        return ApplyOutcome.skipped;
      }

      final result = await _hostKeys.putIfNoConflict(pin);
      if (result == HostKeyInstallResult.conflict) {
        // A conflicting pin is quarantined unapplied — reported through the
        // re-derived diff, never silently trusted.
        return ApplyOutcome.skipped;
      }

      return ApplyOutcome.applied;
    });
  }

  /// Never honoured: a `hostkey:` tombstone would hand the sync server a
  /// primitive for stripping this device's pins.
  @override
  Future<ApplyOutcome> applyTombstone(
    EncryptedRecord record,
    ApplyContext context,
  ) async => ApplyOutcome.skipped;

  /// Pins are not part of §3.1's re-seal set: the recovery re-seals
  /// materialized rows and credentials, never the local TOFU store.
  @override
  Future<int> reSealAfterStoreLoss(CatalogWriter writer) async => 0;

  @override
  Future<DecryptedRecord?> reSourcePending(EncryptedRecord record) async {
    HostKey? pin;
    for (final key in await _hostKeys.all()) {
      if (key.recordId == record.id) pin = key;
    }
    if (pin == null) return null;
    return DecryptedRecord(
      id: record.id,
      kind: RecordKind.hostKey,
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      data: pin.toJson(),
    );
  }
}
