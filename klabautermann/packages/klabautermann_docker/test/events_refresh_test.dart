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
    test('targets the lists one event invalidates', () {
      expect(
        planEventRefresh(event: event('container', action: 'start')).lists,
        {DockerList.containers, DockerList.stacks},
      );
      expect(planEventRefresh(event: event('volume')).lists, {
        DockerList.volumes,
      });
    });
  });
}
