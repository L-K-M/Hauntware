import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/sync_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _conflict = SyncPinConflict(
  locator: 'alpha.example.com:22',
  localFingerprintSha256: 'SHA256:local',
  pulledFingerprintSha256: 'SHA256:pulled',
);

void main() {
  test(
    'dispose settles a pending call, and later calls send nothing',
    () async {
      final engine = FakeEngineClient();
      final sync = SyncController(engine);
      final pending = sync.syncNow();
      expect(engine.sentOfType<RunSyncRound>(), hasLength(1));

      sync.dispose();

      final status = await pending.timeout(const Duration(seconds: 1));
      expect(status.phase, SyncPhase.failed);
      expect(status.operation, SyncOperation.round);

      final late = await sync.syncNow();
      expect(late.phase, SyncPhase.failed);
      expect(engine.sentOfType<RunSyncRound>(), hasLength(1));
    },
  );

  test('a sync status and a PinConflictsChanged update the conflicts',
      () async {
    final engine = FakeEngineClient();
    final sync = SyncController(engine);

    engine.emit(
      const SyncStatus(
        SyncPhase.succeeded,
        operation: SyncOperation.round,
        pinConflicts: [_conflict],
      ),
    );
    await pumpEventQueue();
    expect(sync.conflicts, [_conflict]);

    const next = SyncPinConflict(
      locator: 'bravo.example.com:22',
      localFingerprintSha256: 'SHA256:local-b',
      pulledFingerprintSha256: 'SHA256:pulled-b',
    );
    engine.emit(PinConflictsChanged([next]));
    await pumpEventQueue();
    expect(sync.conflicts, [next]);

    sync.dispose();
  });

  test('a resolution sends one request, marks resolving, and completes on '
      'the answer', () async {
    final engine = FakeEngineClient();
    final sync = SyncController(engine);

    final resolved = sync.resolvePinConflict(
      _conflict,
      keepLocal: true,
    );

    expect(engine.sentOfType<ResolvePinConflict>(), hasLength(1));
    expect(sync.resolving, isTrue);

    engine.emit(PinConflictsChanged([]));
    await resolved;

    expect(sync.resolving, isFalse);
    sync.dispose();
  });

  test('a second resolution of the same conflict is refused while the first '
      'is in flight', () async {
    final engine = FakeEngineClient();
    final sync = SyncController(engine);

    final first = sync.resolvePinConflict(_conflict, keepLocal: true);
    await expectLater(
      sync.resolvePinConflict(_conflict, keepLocal: false),
      throwsA(isA<PinConflictNotResolvedException>()),
    );
    expect(engine.sentOfType<ResolvePinConflict>(), hasLength(1));

    engine.emit(PinConflictsChanged([]));
    await first;
    sync.dispose();
  });

  test('a refusal fails the pending resolution', () async {
    final engine = FakeEngineClient();
    final sync = SyncController(engine);

    final resolved = sync.resolvePinConflict(
      _conflict,
      keepLocal: false,
    );
    engine.emit(const RequestRejected('ResolvePinConflict', 'no vault key'));

    await expectLater(
      resolved,
      throwsA(isA<PinConflictNotResolvedException>()),
    );
    expect(sync.resolving, isFalse);
    sync.dispose();
  });

  test('a startup read updates the conflicts and survives a refusal',
      () async {
    final engine = FakeEngineClient();
    final sync = SyncController(engine);

    final read = sync.readPinConflicts();
    expect(engine.sentOfType<ReadPinConflicts>(), hasLength(1));
    engine.emit(PinConflictsChanged([_conflict]));
    await read;
    expect(sync.conflicts, [_conflict]);

    final refused = sync.readPinConflicts();
    engine.emit(const RequestRejected('ReadPinConflicts', 'locked'));
    await refused;
    expect(sync.conflicts, [_conflict]);

    sync.dispose();
  });
}
