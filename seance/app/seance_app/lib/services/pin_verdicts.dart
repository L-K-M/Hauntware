import 'package:seance_core/catalog.dart' show PinVerdictStore;

import 'app_settings.dart';

/// The pulled-pin verdicts (catalog-library.md §7) in settings.json, never
/// in the sync mirror: the mirror is rebuilt every round, and a verdict kept
/// there would be gone by the next one. Mirrors Poltergeist's
/// `SettingsPinVerdictStore`.
///
/// Callers serialize mutations ([PulledPinResolver] does, through its
/// gate). A failed save puts the in-memory settings back, so they never
/// claim a verdict the file does not hold.
final class SettingsPinVerdictStore implements PinVerdictStore {
  SettingsPinVerdictStore({required this._settings, required this._save});

  final AppSettings Function() _settings;
  final Future<void> Function() _save;

  @override
  Future<Set<String>> negativePins() async =>
      Set.of(_settings().untrustedPinLocators);

  /// Untrusting an address also drops its kept verdict: the verdict belonged
  /// to the trust being withdrawn.
  @override
  Future<void> addNegativePin(String locator) => _edit((s) {
    final added = s.untrustedPinLocators.add(locator);
    final dropped = s.keptPinVerdicts.remove(locator) != null;
    return added || dropped;
  });

  @override
  Future<void> removeNegativePin(String locator) =>
      _edit((s) => s.untrustedPinLocators.remove(locator));

  @override
  Future<String?> rejectedFingerprintFor(String locator) async =>
      _settings().keptPinVerdicts[locator];

  @override
  Future<void> recordKeptVerdict(String locator, String rejectedFingerprint) =>
      _edit((s) {
        if (s.keptPinVerdicts[locator] == rejectedFingerprint) return false;
        s.keptPinVerdicts[locator] = rejectedFingerprint;
        return true;
      });

  /// Applies [change] and saves when it changed anything.
  Future<void> _edit(bool Function(AppSettings settings) change) async {
    final s = _settings();
    final untrusted = Set.of(s.untrustedPinLocators);
    final kept = Map.of(s.keptPinVerdicts);
    if (!change(s)) return;
    try {
      await _save();
    } catch (_) {
      s.untrustedPinLocators
        ..clear()
        ..addAll(untrusted);
      s.keptPinVerdicts
        ..clear()
        ..addAll(kept);
      rethrow;
    }
  }
}
