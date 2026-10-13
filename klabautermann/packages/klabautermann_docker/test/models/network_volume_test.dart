import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import '../harness.dart';

Object? fixtureJson(String name) => jsonDecode(fixtureString(name));

void main() {
  group('networks', () {
    test('parses the list, built-in flag and attached containers', () {
      final r = parseNetworkSummaries(fixtureJson('networks-1.44.json'));
      expect(r.warnings, isEmpty);
      expect(r.value, hasLength(2));

      final bridge = r.value.first;
      expect(bridge.name, 'bridge');
      expect(bridge.isBuiltin, isTrue);
      expect(bridge.subnet, '172.17.0.0/16');

      final web = r.value[1];
      expect(web.isBuiltin, isFalse);
      expect(web.driver, 'bridge');
      expect(web.containers, hasLength(1));
      expect(web.containers.values.first.name, 'web-1');
      expect(web.labels['com.docker.compose.project']!.display, 'web');
    });

    test('never throws on malformed daemon input', () {
      expect(parseNetworkSummaries(null).warnings, isNotEmpty);
      expect(parseNetworkSummaries(const <Object?>['x']).warnings, isNotEmpty);
    });
  });

  group('volumes', () {
    test('parses the volumes document with warnings and options', () {
      final r = parseVolumeSummaries(fixtureJson('volumes-1.44.json'));
      expect(r.warnings, isEmpty);
      expect(r.value, hasLength(2));
      expect(r.value.first.name, 'web_data');
      expect(r.value.first.driver, 'local');
      expect(
        r.value.first.mountpoint,
        '/var/lib/docker/volumes/web_data/_data',
      );
      expect(r.value[1].options['device'], '/tmp/x');
    });

    test('accepts a bare array too', () {
      final r = parseVolumeSummaries([
        {'Name': 'solo'},
      ]);
      expect(r.value.single.name, 'solo');
    });

    test('never throws on malformed daemon input', () {
      expect(parseVolumeSummaries(null).warnings, isNotEmpty);
      expect(parseVolumeSummaries(42).warnings, isNotEmpty);
    });
  });
}
