import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import 'harness.dart';

Object? fixtureJson(String name) => jsonDecode(fixtureString(name));

List<ContainerSummary> containers(String name) =>
    parseContainerSummaries(fixtureJson(name)).value;

List<ImageSummary> images(String name, {required bool countGate}) =>
    parseImageSummaries(
      fixtureJson(name),
      includeContainerCount: countGate,
    ).value;

void main() {
  group('container counts', () {
    test('splits running, paused and stopped and counts unhealthy', () {
      final s = dockerSummary(containers('containers-1.52.json'), const []);
      expect(s.running, 2);
      expect(s.paused, 1);
      // Exited and created both count as stopped, as `docker info` does.
      expect(s.stopped, 2);
      expect(s.unhealthy, 1);
    });

    test('reads unhealthy from the status text below 1.52', () {
      final s = dockerSummary(containers('containers-1.44.json'), const []);
      expect(s.running, 3);
      expect(s.stopped, 1);
      expect(s.unhealthy, 1);
    });

    test('a container without a state counts as stopped', () {
      final s = dockerSummary(const [ContainerSummary(id: 'x')], const []);
      expect(s.stopped, 1);
      expect(s.running, 0);
      expect(s.unhealthy, 0);
    });
  });

  group('images in use', () {
    test('below 1.51 the container list decides', () {
      final s = dockerSummary(
        containers('containers-1.52.json'),
        images('images-1.52.json', countGate: false),
      );
      expect(s.images, 2);
      // alpine backs web, worker, cron and init; the dangling image backs
      // the exited job, which still keeps it in use.
      expect(s.imagesInUse, 2);
      expect(s.danglingImages, 1);
    });

    test('below 1.51 an image no container names is unused', () {
      final s = dockerSummary(
        const [],
        images('images-1.52.json', countGate: false),
      );
      expect(s.imagesInUse, 0);
      expect(s.danglingImages, 1);
    });

    test('from 1.51 the Containers count decides', () {
      final s = dockerSummary(
        const [],
        images('images-1.55.json', countGate: true),
      );
      expect(s.images, 2);
      expect(s.imagesInUse, 1);
      expect(s.danglingImages, 1);
    });

    test('an uncomputed count (-1) falls back to the container list', () {
      const image = ImageSummary(id: 'sha256:abc', containers: -1);
      const user = ContainerSummary(id: 'c', imageId: 'abc');
      expect(dockerSummary(const [user], const [image]).imagesInUse, 1);
      expect(dockerSummary(const [], const [image]).imagesInUse, 0);
    });
  });

  group('reclaimable space', () {
    test('is unknown until /system/df was fetched', () {
      final s = dockerSummary(const [], const []);
      expect(s.reclaimableBytes, isNull);
      expect(s.running + s.paused + s.stopped + s.unhealthy, 0);
      expect(s.images + s.imagesInUse + s.danglingImages, 0);
    });

    test('sums the reported types from /system/df', () {
      final df = parseSystemDf(
        fixtureJson('system-df-1.53.json'),
        shape: SystemDfShape.v153,
      ).value;
      final s = dockerSummary(const [], const [], df);
      expect(s.reclaimableBytes, 1159725056);
    });

    test('stays unknown when /system/df reported no figure', () {
      final s = dockerSummary(const [], const [], const SystemDf());
      expect(s.reclaimableBytes, isNull);
    });
  });
}
