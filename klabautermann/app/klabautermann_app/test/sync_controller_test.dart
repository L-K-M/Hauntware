import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/sync_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

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
