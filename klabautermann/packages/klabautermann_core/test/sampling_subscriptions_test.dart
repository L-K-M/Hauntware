import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/sampling/subscriptions.dart';
import 'package:test/test.dart';

Subscribe _subscribe(
  String subscriptionId,
  Set<SampleStream> streams, {
  String serverId = 'srv-1',
}) => Subscribe(
  serverId: serverId,
  subscriptionId: subscriptionId,
  streams: streams,
);

Unsubscribe _unsubscribe(String subscriptionId, {String serverId = 'srv-1'}) =>
    Unsubscribe(serverId: serverId, subscriptionId: subscriptionId);

void main() {
  group('SamplingSubscriptions (D45)', () {
    late SamplingSubscriptions subscriptions;

    setUp(() => subscriptions = SamplingSubscriptions());

    test('a server samples the union of its subscriptions', () {
      subscriptions
        ..subscribe(_subscribe('row', {SampleStream.overview}))
        ..subscribe(
          _subscribe('overview', {SampleStream.core, SampleStream.fs}),
        )
        ..subscribe(_subscribe('row', {SampleStream.fs}, serverId: 'srv-2'));

      expect(subscriptions.streamsFor('srv-1'), {
        SampleStream.overview,
        SampleStream.core,
        SampleStream.fs,
      });
      expect(subscriptions.streamsFor('srv-2'), {SampleStream.fs});
      expect(subscriptions.streamsFor('srv-3'), isEmpty);
      expect(subscriptions.servers, {'srv-1', 'srv-2'});
      // What a refresh reads: one subscription's own streams.
      expect(subscriptions.streamsOf('srv-1', 'overview'), {
        SampleStream.core,
        SampleStream.fs,
      });
      expect(subscriptions.streamsOf('srv-1', 'system'), isNull);
      expect(subscriptions.streamsOf('srv-3', 'row'), isNull);
    });

    test('dropping one surface keeps the streams another names', () {
      subscriptions
        ..subscribe(_subscribe('row', {SampleStream.overview}))
        ..subscribe(
          _subscribe('overview', {SampleStream.overview, SampleStream.core}),
        )
        ..unsubscribe(_unsubscribe('overview'));

      // The M1 engine kept one subscription per server, so closing the
      // overview would have stopped the fleet row's sampling too.
      expect(subscriptions.streamsFor('srv-1'), {SampleStream.overview});

      subscriptions.unsubscribe(_unsubscribe('row'));
      expect(subscriptions.streamsFor('srv-1'), isEmpty);
      expect(subscriptions.servers, isEmpty);
    });

    test('the same ids replace their streams; an empty set drops them', () {
      subscriptions
        ..subscribe(_subscribe('panel', {SampleStream.units}))
        ..subscribe(_subscribe('card', {SampleStream.failedUnits}))
        ..subscribe(_subscribe('panel', {SampleStream.procs}));
      expect(subscriptions.streamsFor('srv-1'), {
        SampleStream.failedUnits,
        SampleStream.procs,
      });

      subscriptions
        ..subscribe(_subscribe('panel', const {}))
        ..subscribe(_subscribe('card', const {}));
      expect(subscriptions.servers, isEmpty);
    });

    test('unknown subscriptions are ignored', () {
      subscriptions
        ..subscribe(_subscribe('row', {SampleStream.overview}))
        ..unsubscribe(_unsubscribe('other'))
        ..unsubscribe(_unsubscribe('row', serverId: 'srv-2'));

      expect(subscriptions.streamsFor('srv-1'), {SampleStream.overview});
    });

    test('a server the fleet no longer lists loses its subscriptions, and '
        'takes none until it is back (03 §5.1)', () {
      subscriptions
        ..subscribe(_subscribe('row', {SampleStream.overview}))
        ..subscribe(_subscribe('row', {SampleStream.fs}, serverId: 'srv-2'))
        ..fleet = {'srv-2'}
        // Sent before the app heard that srv-1 left.
        ..subscribe(_subscribe('panel', {SampleStream.procs}));
      expect(subscriptions.servers, {'srv-2'});

      subscriptions
        ..fleet = {'srv-1', 'srv-2'}
        ..subscribe(_subscribe('panel', {SampleStream.procs}));
      expect(subscriptions.streamsFor('srv-1'), {SampleStream.procs});
      expect(subscriptions.streamsFor('srv-2'), {SampleStream.fs});
    });

    test('the cadence profile starts at the Desktop column', () {
      expect(subscriptions.profile, CadenceProfile.desktop);
    });

    test('held stream sets cannot be edited from outside', () {
      final streams = {SampleStream.overview};
      subscriptions.subscribe(_subscribe('row', streams));
      streams.add(SampleStream.procs);

      expect(subscriptions.streamsFor('srv-1'), {SampleStream.overview});
      expect(() => subscriptions.servers.add('srv-9'), throwsUnsupportedError);
    });
  });
}
