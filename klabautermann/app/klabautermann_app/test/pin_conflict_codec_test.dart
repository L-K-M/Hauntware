import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show SyncPinConflict;

void main() {
  const conflict = SyncPinConflict(
    locator: 'host.example:22',
    localFingerprintSha256: 'SHA256:local',
    pulledFingerprintSha256: 'SHA256:pulled',
  );

  test('incomplete or mistyped snapshot conflicts decode as absent', () {
    final valid = encodePinConflict(conflict);
    for (final key in valid.keys) {
      final missing = Map<String, Object?>.of(valid)..remove(key);
      expect(decodePinConflict(missing), isNull, reason: 'missing $key');
      final mistyped = Map<String, Object?>.of(valid)..[key] = 42;
      expect(decodePinConflict(mistyped), isNull, reason: 'mistyped $key');
    }
    expect(decodePinConflict(null), isNull);
    expect(decodePinConflict('not a map'), isNull);
  });

  test('a malformed snapshot entry does not hide well-formed conflicts', () {
    expect(decodePinConflicts([{}, encodePinConflict(conflict), 'not a map']), [
      conflict,
    ]);
  });
}
