// The sync passwords switch (03 §4.5): a change the engine refuses is
// neither kept nor announced.
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/sync_secrets_controller.dart';

void main() {
  test('a change the engine never took is not kept', () async {
    var refuse = false;
    final controller = SyncSecretsController(
      apply: (_) {
        if (refuse) throw StateError('engine gone');
      },
    );
    addTearDown(controller.dispose);
    var notified = 0;
    controller.addListener(() => notified++);

    refuse = true;
    await expectLater(controller.setSyncSecrets(true), throwsStateError);

    expect(controller.value, isFalse);
    expect(notified, 0);
  });
}
