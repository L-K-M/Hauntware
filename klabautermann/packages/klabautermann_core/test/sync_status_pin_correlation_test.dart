import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

void main() {
  test('answering a requested sync retains the host-key conflict diff', () {
    const conflict = SyncPinConflict(
      locator: 'host.example:22',
      localFingerprintSha256: 'SHA256:local',
      pulledFingerprintSha256: 'SHA256:pulled',
    );
    const status = SyncStatus(
      SyncPhase.succeeded,
      operation: SyncOperation.round,
      pinConflicts: [conflict],
    );

    final answer = status.answering('requested-round');

    expect(answer.requestId, 'requested-round');
    expect(answer.pinConflicts, [conflict]);
  });
}
