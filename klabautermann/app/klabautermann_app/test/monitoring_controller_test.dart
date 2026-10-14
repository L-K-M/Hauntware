import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

Sample _sample(String serverId, SampleStream stream, int seq) => Sample(
  serverId: serverId,
  stream: stream,
  seq: seq,
  at: DateTime.utc(2026, 10, 14, 12, 0, seq),
  // Valid for every stream, which `Sample` asserts.
  result: const CollectorUnavailable(CollectorUnavailableReason.timeout),
);

void main() {
  late FakeEngineClient engine;
  late MonitoringController monitoring;

  setUp(() {
    engine = FakeEngineClient();
    monitoring = MonitoringController(engine);
  });

  tearDown(() async {
    monitoring.dispose();
    await engine.close();
  });

  /// Lets the fake engine's broadcast events reach the controller.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('subscriptions (D45)', () {
    test('each surface subscribes with its own id and streams', () {
      monitoring
        ..subscribe('srv-1', 'row', {SampleStream.overview})
        ..subscribe('srv-1', 'overview', {SampleStream.core, SampleStream.fs});

      final [row, overview] = engine.sentOfType<Subscribe>().cast<Subscribe>();
      expect(row.serverId, 'srv-1');
      expect(row.subscriptionId, 'row');
      expect(row.streams, {SampleStream.overview});
      expect(overview.subscriptionId, 'overview');
      expect(overview.streams, {SampleStream.core, SampleStream.fs});
      expect(monitoring.isSubscribed('srv-1', 'row'), isTrue);
      expect(monitoring.isSubscribed('srv-1', 'overview'), isTrue);
      expect(monitoring.isSubscribed('srv-2', 'row'), isFalse);
    });

    test('unsubscribing one surface leaves the others subscribed', () {
      monitoring
        ..subscribe('srv-1', 'row', {SampleStream.overview})
        ..subscribe('srv-1', 'overview', {SampleStream.core})
        ..unsubscribe('srv-1', 'overview')
        // Already gone, or never subscribed: nothing to send.
        ..unsubscribe('srv-1', 'overview')
        ..unsubscribe('srv-2', 'row');

      final [unsubscribe] = engine
          .sentOfType<Unsubscribe>()
          .cast<Unsubscribe>();
      expect(unsubscribe.serverId, 'srv-1');
      expect(unsubscribe.subscriptionId, 'overview');
      expect(monitoring.isSubscribed('srv-1', 'overview'), isFalse);
      expect(monitoring.isSubscribed('srv-1', 'row'), isTrue);
    });
  });

  group('samples (03 §10.1)', () {
    test('land in the box of their server and stream only', () async {
      var notified = 0;
      monitoring.addListener(() => notified++);
      final rowBox = monitoring.sampleFor('srv-1', SampleStream.overview);
      var rowUpdates = 0;
      rowBox.addListener(() => rowUpdates++);

      final row = _sample('srv-1', SampleStream.overview, 1);
      final core = _sample('srv-1', SampleStream.core, 2);
      final other = _sample('srv-2', SampleStream.overview, 1);
      engine
        ..emit(row)
        ..emit(core)
        ..emit(other)
        ..emit(const LinkState('srv-1', LinkReady()));
      await settle();

      expect(rowBox.value, same(row));
      expect(rowUpdates, 1);
      expect(
        monitoring.sampleFor('srv-1', SampleStream.core).value,
        same(core),
      );
      expect(
        monitoring.sampleFor('srv-2', SampleStream.overview).value,
        same(other),
      );
      expect(monitoring.sampleFor('srv-2', SampleStream.core).value, isNull);
      // §10.1: a tick never rebuilds what listens to the whole controller.
      expect(notified, 0);
    });

    test(
      'a sample not above its server\'s last seq is dropped (D44)',
      () async {
        final first = _sample('srv-1', SampleStream.overview, 5);
        engine
          ..emit(first)
          // One counter per server: a lower or equal seq on another stream
          // of the same server is stale too.
          ..emit(_sample('srv-1', SampleStream.core, 4))
          ..emit(_sample('srv-1', SampleStream.overview, 5))
          // Another server counts on its own.
          ..emit(_sample('srv-2', SampleStream.overview, 1));
        await settle();

        expect(
          monitoring.sampleFor('srv-1', SampleStream.overview).value,
          same(first),
        );
        expect(monitoring.sampleFor('srv-1', SampleStream.core).value, isNull);
        expect(
          monitoring.sampleFor('srv-2', SampleStream.overview).value?.seq,
          1,
        );

        final next = _sample('srv-1', SampleStream.core, 6);
        engine.emit(next);
        await settle();
        expect(
          monitoring.sampleFor('srv-1', SampleStream.core).value,
          same(next),
        );
      },
    );
  });
}
