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
}
