// The engine's safety policy rules (M4 plan M4): observe-only by default,
// read-only above it, and only the Safety tab's expiries.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/safety_policy.dart';
import 'package:test/test.dart';

void main() {
  test('a server is observe-only until management is on', () {
    expect(
      safetyRefusal(const SafetyPolicy(), 'srv-1'),
      ActionRefusalReason.observeOnly,
    );
    const managed = SafetyPolicy(
      servers: {'srv-1': ServerSafety(management: true)},
    );
    expect(safetyRefusal(managed, 'srv-1'), isNull);
    expect(safetyRefusal(managed, 'srv-2'), ActionRefusalReason.observeOnly);
    expect(adminRefusal(managed, 'srv-1'), isNull);
    expect(adminRefusal(managed, 'srv-2'), AdminFailure.observeOnly);
  });

  test('read-only, global or per server, wins over management', () {
    for (final policy in const [
      SafetyPolicy(
        globalReadOnly: true,
        servers: {'srv-1': ServerSafety(management: true)},
      ),
      SafetyPolicy(
        servers: {'srv-1': ServerSafety(management: true, readOnly: true)},
      ),
    ]) {
      expect(safetyRefusal(policy, 'srv-1'), ActionRefusalReason.readOnly);
      expect(adminRefusal(policy, 'srv-1'), AdminFailure.readOnly);
    }
  });

  test('takes only the expiries the Safety tab offers', () {
    for (final expiry in kAdminExpiryChoices) {
      expect(validateSafetyPolicy(SafetyPolicy(adminExpiry: expiry)), isNull);
    }
    expect(
      validateSafetyPolicy(
        const SafetyPolicy(adminExpiry: Duration(minutes: 7)),
      ),
      isNotNull,
    );
  });
}
