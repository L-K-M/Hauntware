// CRED-05's app-side recovery controller: requestId correlation, bounded
// waits, fixed failures, and cleanup on disconnect and dispose. The
// engine's crypto and vault matrix live in klabautermann_core's
// engine_recovery_test.dart.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/recovery_controller.dart';
import 'package:klabautermann_app/services/recovery_files.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

/// The file panels with scripted answers.
final class _FakeFiles implements RecoveryFiles {
  Uint8List? next;
  Uint8List? savedBytes;
  String? savedName;
  Object? saveError;
  bool cancelSave = false;

  @override
  Future<String?> save(Uint8List bytes, String fileName) async {
    final error = saveError;
    if (error != null) throw error;
    if (cancelSave) return null;
    savedBytes = bytes;
    savedName = fileName;
    return '/tmp/$fileName';
  }

  @override
  Future<Uint8List?> open() async => next;
}

void main() {
  late FakeEngineClient engine;
  late _FakeFiles files;
  late RecoveryController controller;

  setUp(() async {
    engine = FakeEngineClient();
    files = _FakeFiles();
    controller = RecoveryController(
      engine,
      files,
      requestTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(() async {
      controller.dispose();
      await engine.close();
    });
    // The constructor reads the configured flag; answer it so every test
    // starts from a known status.
    final status = engine.sent.whereType<RecoveryStatusRequest>().single;
    engine.emit(RecoveryStatus(requestId: status.requestId, configured: false));
    await controller.recoveryConfigured();
  });

  test('loads the configured flag from the correlated reply', () async {
    final pending = controller.refresh();
    final status = engine.sent.whereType<RecoveryStatusRequest>().last;

    engine.emit(RecoveryStatus(requestId: status.requestId, configured: true));
    await pending;

    expect(controller.configured, isTrue);
  });

  test('a status failure is explicit and a later refresh can retry', () async {
    final failed = controller.refresh();
    final request = engine.sent.whereType<RecoveryStatusRequest>().last;
    engine.emit(
      VaultRecoveryFailed(
        requestId: request.requestId,
        failure: VaultRecoveryFailure.keystoreUnavailable,
      ),
    );
    await expectLater(failed, throwsA(isA<RecoveryException>()));

    final retried = controller.refresh();
    final retry = engine.sent.whereType<RecoveryStatusRequest>().last;
    engine.emit(RecoveryStatus(requestId: retry.requestId, configured: true));
    await retried;
    expect(controller.configured, isTrue);
  });

  test('an unlock refresh failure stays inside the controller', () async {
    controller.refreshAfterUnlock();
    final request = engine.sent.whereType<RecoveryStatusRequest>().last;
    engine.emit(
      VaultRecoveryFailed(
        requestId: request.requestId,
        failure: VaultRecoveryFailure.keystoreUnavailable,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final retried = controller.refresh();
    final retry = engine.sent.whereType<RecoveryStatusRequest>().last;
    engine.emit(RecoveryStatus(requestId: retry.requestId, configured: true));
    await retried;
    expect(controller.configured, isTrue);
  });

  test('a status timeout is not reported as a successful refresh', () async {
    await expectLater(controller.refresh(), throwsA(isA<RecoveryException>()));
  });

  test(
    'a new code comes from the correlated reply, not an unrelated one',
    () async {
      final pending = controller.newCode();
      final request = engine.sent.whereType<NewRecoveryCode>().single;
      const code = 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-89AB';

      // A reply for another request id is ignored.
      engine.emit(
        RecoveryCodeGenerated(requestId: 'another-request', code: 'OTHER-CODE'),
      );
      engine.emit(
        RecoveryCodeGenerated(requestId: request.requestId, code: code),
      );

      expect(await pending, code);
    },
  );

  test('a fixed failure is reported without diagnostic text', () async {
    final pending = controller.exportSecrets();
    final request = engine.sent.whereType<ExportVault>().single;

    engine.emit(
      VaultRecoveryFailed(
        requestId: request.requestId,
        failure: VaultRecoveryFailure.wrongCode,
      ),
    );

    await expectLater(
      pending,
      throwsA(
        isA<RecoveryException>().having(
          (error) => error.failure,
          'failure',
          VaultRecoveryFailure.wrongCode,
        ),
      ),
    );
    expect(files.savedBytes, isNull, reason: 'nothing is written');
  });

  test(
    'a request that is never answered fails with the generic kind',
    () async {
      final pending = controller.newCode();

      await expectLater(
        pending,
        throwsA(
          isA<RecoveryException>().having(
            (error) => error.failure,
            'failure',
            VaultRecoveryFailure.failed,
          ),
        ),
      );
    },
  );

  test(
    'a disconnect completes pending requests with a fixed failure',
    () async {
      final pending = controller.newCode();

      await engine.close();

      await expectLater(
        pending,
        throwsA(
          isA<RecoveryException>().having(
            (error) => error.failure,
            'failure',
            VaultRecoveryFailure.failed,
          ),
        ),
      );
    },
  );

  test('dispose completes pending requests with a fixed failure', () async {
    final pending = controller.newCode();

    controller.dispose();

    await expectLater(
      pending,
      throwsA(
        isA<RecoveryException>().having(
          (error) => error.failure,
          'failure',
          VaultRecoveryFailure.failed,
        ),
      ),
    );
  });

  test('saveCode sends the code and applies the status reply', () async {
    const code = 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-89AB';
    final pending = controller.saveCode(code);
    final request = engine.sent.whereType<SetRecoveryCode>().single;

    expect(request.code, code);
    engine.emit(RecoveryStatus(requestId: request.requestId, configured: true));

    await pending;
    expect(controller.configured, isTrue);
  });

  test('export saves the correlated bytes under the dated name', () async {
    final pending = controller.exportSecrets();
    final request = engine.sent.whereType<ExportVault>().single;
    final bytes = Uint8List.fromList([1, 2, 3]);

    engine.emit(VaultExported(requestId: request.requestId, bytes: bytes));

    final destination = await pending;
    expect(destination, isNotNull);
    expect(files.savedBytes, bytes);
    expect(files.savedName, startsWith('klabautermann-secrets-'));
    expect(files.savedName, endsWith('.json'));
  });

  test('a cancelled save reports no destination', () async {
    files.cancelSave = true;
    final pending = controller.exportSecrets();
    final request = engine.sent.whereType<ExportVault>().single;
    engine.emit(
      VaultExported(requestId: request.requestId, bytes: Uint8List(0)),
    );

    expect(await pending, isNull);
    expect(files.savedBytes, isNull);
  });

  test('a file save failure crosses as a fixed file failure', () async {
    files.saveError = const RecoveryFileException(
      RecoveryFileFailure.saveFailed,
    );
    final pending = controller.exportSecrets();
    final request = engine.sent.whereType<ExportVault>().single;
    engine.emit(
      VaultExported(requestId: request.requestId, bytes: Uint8List(0)),
    );

    await expectLater(pending, throwsA(isA<RecoveryFileException>()));
  });

  test('restore opens the file and sends the code and policy', () async {
    files.next = Uint8List.fromList([4, 5, 6]);
    final pending = controller.restoreSecrets(
      code: 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-89AB',
      policy: VaultRestorePolicy.replaceExisting,
    );
    // The file panel is awaited before the request is sent.
    await Future<void>.delayed(Duration.zero);
    final request = engine.sent.whereType<RestoreVault>().single;

    expect(request.code, 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-89AB');
    expect(request.policy, VaultRestorePolicy.replaceExisting);
    expect(request.export, files.next);
    engine.emit(
      VaultRestored(
        requestId: request.requestId,
        added: 1,
        replaced: 2,
        kept: 3,
        unreadable: 4,
      ),
    );

    final summary = await pending;
    expect(summary, isNotNull);
    expect(
      (summary!.added, summary.replaced, summary.kept, summary.unreadable),
      (1, 2, 3, 4),
    );
  });

  test('a cancelled file panel restores nothing', () async {
    files.next = null;

    expect(
      await controller.restoreSecrets(
        code: 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-89AB',
        policy: VaultRestorePolicy.keepExisting,
      ),
      isNull,
    );
    expect(engine.sent.whereType<RestoreVault>(), isEmpty);
  });
}
