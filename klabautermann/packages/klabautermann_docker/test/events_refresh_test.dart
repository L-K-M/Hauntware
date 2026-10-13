import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

DockerEvent event(String type, {String action = 'create'}) =>
    DockerEvent(type: type, action: action);

void main() {
  group('listsForEvent (03 §7.12 DKE-02)', () {
    test('maps each event family to its list', () {
      expect(listsForEvent(event('container')), {
        DockerList.containers,
        DockerList.stacks,
      });
      expect(listsForEvent(event('image')), {DockerList.images});
      expect(listsForEvent(event('volume')), {DockerList.volumes});
      expect(listsForEvent(event('network')), {DockerList.networks});
      expect(listsForEvent(event('daemon')), {DockerList.engineInfo});
      expect(listsForEvent(event('plugin')), isEmpty);
    });
  });

  group('planEventRefresh (03 §7.12 DKE-02)', () {
    final now = DateTime.utc(2026, 5, 1, 12);

    test('targets a list for a normal event', () {
      final plan = planEventRefresh(
        event: event('container', action: 'start'),
        now: now,
        previousEventAt: now.subtract(const Duration(seconds: 5)),
      );
      expect(plan.fullRelist, isFalse);
      expect(plan.lists, {DockerList.containers, DockerList.stacks});
    });

    test('re-lists everything after a gap over 60 s', () {
      final plan = planEventRefresh(
        event: event('image', action: 'pull'),
        now: now,
        previousEventAt: now.subtract(const Duration(seconds: 61)),
      );
      expect(plan.fullRelist, isTrue);
      expect(plan.lists, DockerList.all);
      expect(plan.reason, contains('61'));
    });

    test('exactly 60 s is not a gap', () {
      final plan = planEventRefresh(
        event: event('image'),
        now: now,
        previousEventAt: now.subtract(const Duration(seconds: 60)),
      );
      expect(plan.fullRelist, isFalse);
    });

    test('no previous event means no known gap', () {
      final plan = planEventRefresh(event: event('volume'), now: now);
      expect(plan.fullRelist, isFalse);
      expect(plan.lists, {DockerList.volumes});
    });
  });
}
