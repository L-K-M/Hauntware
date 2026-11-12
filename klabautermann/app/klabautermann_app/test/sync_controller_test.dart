import 'dart:async';

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

  test('disposing during resolution preserves the typed refusal', () async {
    final engine = FakeEngineClient();
    final sync = SyncController(engine);
    final pending = sync.resolvePinConflict(_conflict, keepLocal: false);
    final refused = expectLater(
      pending,
      throwsA(isA<PinConflictNotResolvedException>()),
    );

    sync.dispose();

    await refused;
    await engine.close();
  });

  test('an engine stop still notifies that resolution ended', () async {
    final engine = FakeEngineClient();
    final sync = SyncController(engine);
    final observed = <bool>[];
    sync.addListener(() => observed.add(sync.resolving));
    final pending = sync.resolvePinConflict(_conflict, keepLocal: true);
    final refused = expectLater(
      pending,
      throwsA(isA<PinConflictNotResolvedException>()),
    );

    await engine.close();
    await refused;

    expect(sync.resolving, isFalse);
    expect(observed.last, isFalse);
    sync.dispose();
  });

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

  test('a round the engine started itself does not answer a requested '
      'one', () async {
    final engine = FakeEngineClient();
    final sync = SyncController(engine);
    addTearDown(() async {
      sync.dispose();
      await engine.close();
    });

    // A catalog write just took, so the engine runs its own round, and
    // the user asks for one behind it.
    engine.emit(
      const SyncStatus(SyncPhase.running, operation: SyncOperation.round),
    );
    await pumpEventQueue();
    expect(sync.busy, isTrue, reason: 'the engine is running a round');
    final pending = sync.syncNow();
    final request = engine.sentOfType<RunSyncRound>().single as RunSyncRound;
    expect(request.requestId, isNotNull);

    var answered = false;
    unawaited(pending.then((_) => answered = true));
    engine.emit(
      const SyncStatus(
        SyncPhase.failed,
        operation: SyncOperation.round,
        failure: SyncFailure.unreachable,
      ),
    );
    await pumpEventQueue();
    expect(answered, isFalse);
    expect(sync.busy, isTrue);

    engine.emit(
      SyncStatus(
        SyncPhase.succeeded,
        operation: SyncOperation.round,
        requestId: request.requestId,
      ),
    );
    final status = await pending.timeout(const Duration(seconds: 1));
    expect(status.phase, SyncPhase.succeeded);
    expect(sync.busy, isFalse);
  });

  test('an engine-started round failing does not answer a sign-in', () async {
    final engine = FakeEngineClient();
    final sync = SyncController(engine);
    addTearDown(() async {
      sync.dispose();
      await engine.close();
    });

    final pending = sync.signIn(
      baseUrl: 'https://sync.example.com',
      username: 'ops',
      password: 'pw',
      encryptionPassphrase: 'pp',
    );
    final request = engine.sentOfType<EnrollSync>().single as EnrollSync;

    engine.emit(
      const SyncStatus(
        SyncPhase.failed,
        operation: SyncOperation.round,
        failure: SyncFailure.sessionRejected,
      ),
    );
    engine.emit(
      SyncStatus(
        SyncPhase.succeeded,
        operation: SyncOperation.enroll,
        requestId: request.requestId,
      ),
    );

    final status = await pending.timeout(const Duration(seconds: 1));
    expect(status.operation, SyncOperation.enroll);
    expect(status.phase, SyncPhase.succeeded);
  });
}
