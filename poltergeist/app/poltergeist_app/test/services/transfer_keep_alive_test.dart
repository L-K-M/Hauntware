import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keepalive/ghost_keepalive.dart';
import 'package:poltergeist_app/services/app_transfer_queue.dart';
import 'package:poltergeist_app/services/transfer_keep_alive.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';

/// Records backend calls so the reporter's protocol can be asserted
/// without a platform (the state machine itself is ghost_keepalive's).
final class _RecordingBackend implements BackgroundKeepAliveBackend {
  final calls = <String>[];

  @override
  Future<void> activate(int count) async => calls.add('activate $count');

  @override
  Future<void> countChanged(int count) async => calls.add('count $count');

  @override
  Future<void> deactivate() async => calls.add('deactivate');
}

BackgroundKeepAlive _keepAlive(_RecordingBackend backend) =>
    BackgroundKeepAlive(
      strings: const PoltergeistKeepAliveStrings(),
      backend: backend,
    );

void main() {
  test('anchors on every non-terminal row, sync and archive splices too',
      () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final backend = _RecordingBackend();
      queue.addTask(state: TransferTaskState.running);
      // A paused transfer still needs the anchor: the queue boots paused
      // after a restore (03 §4.6) and must not freeze mid-resume.
      queue.addTask(state: TransferTaskState.paused);
      // Rows the composite queue splices in for sync runs and archive
      // jobs — the anchor covers them exactly like plain transfers.
      queue.addTask(
        state: TransferTaskState.running,
        presentation: AppTaskPresentation.sync,
      );
      final archiveRow = queue.addTask(
        state: TransferTaskState.running,
        presentation: AppTaskPresentation.archiveCreate,
      );

      TransferKeepAliveReporter(queue: queue, keepAlive: _keepAlive(backend));
      expect(backend.calls, ['activate 4']);

      // Terminal rows leave the count: the reporter listens to queue
      // events, so a finishing task re-counts without anyone else's help.
      queue.cancelTask(archiveRow.id);
      async.elapse(Duration.zero);
      expect(backend.calls, ['activate 4', 'count 3']);
    });
  });

  test('an idle queue never anchors', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final backend = _RecordingBackend();

      TransferKeepAliveReporter(queue: queue, keepAlive: _keepAlive(backend));
      async.elapse(const Duration(seconds: 5));
      queue.emitRefresh();
      async.elapse(const Duration(seconds: 5));

      expect(backend.calls, isEmpty);
    });
  });

  test('the last terminal task deactivates after the grace', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final backend = _RecordingBackend();
      final task = queue.addTask(state: TransferTaskState.running);

      TransferKeepAliveReporter(queue: queue, keepAlive: _keepAlive(backend));
      queue.cancelTask(task.id);
      async.elapse(const Duration(seconds: 5));

      expect(backend.calls, ['activate 1', 'deactivate']);
    });
  });

  test('dispose drops the anchor immediately, grace ignored', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final backend = _RecordingBackend();
      queue.addTask(state: TransferTaskState.running);

      final reporter = TransferKeepAliveReporter(
        queue: queue,
        keepAlive: _keepAlive(backend),
      );
      reporter.dispose();
      async.elapse(const Duration(seconds: 5));

      expect(backend.calls, ['activate 1', 'deactivate']);
    });
  });

  test('the strings pin the channel id and the ARB wording', () {
    const strings = PoltergeistKeepAliveStrings();

    // Per-app on purpose: the channel's settings are stored user data,
    // and Séance keeps its own channel.
    expect(strings.channelId, 'poltergeist.keepalive');
    expect(strings.channelName, 'Transfer keep-alive');
    expect(strings.channelDescription,
        'Shown while transfers are kept alive in the background.');
    expect(strings.notificationTitle, 'Poltergeist');
    expect(strings.notificationText(1),
        'Keeping 1 transfer alive in the background.');
    expect(strings.notificationText(2),
        'Keeping 2 transfers alive in the background.');
    expect(strings.smallIconResourceName, 'ic_stat_transfer_keep_alive');
  });
}
