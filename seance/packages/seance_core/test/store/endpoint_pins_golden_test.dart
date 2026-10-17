// Byte golden for `endpoint_pins.json` (D16, 03-ARCHITECTURE.md 4.7 and
// 4.10): fixed pins go through the store's default writer and the file
// is compared byte for byte, so a format change cannot land unnoticed.
//
// Change the golden only for an intentional format change, together with
// the store version, from the actual document a failure prints.
import 'dart:io';

import 'package:seance_core/catalog.dart';
import 'package:test/test.dart';

/// Pins sorted by server id whatever the confirm order; a replaced pin
/// keeps only its newest values; a dropped pin and a drop of a server
/// that never had one leave no trace. The document is ASCII.
const _endpointPinsGolden =
    r'{"version":1,"pins":[{"serverId":"srv-alpha",'
    r'"host":"alpha.example.com","port":22,"username":"deploy",'
    r'"jumpRouteIds":[],"confirmedAt":1791892803000},'
    r'{"serverId":"srv-beta","host":"fd00::7","port":2222,"username":"",'
    r'"jumpRouteIds":["srv-bastion","srv-inner"],'
    r'"confirmedAt":1791892801000}]}';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('endpoint-pins-golden');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'endpoint_pins.json bytes: sorted pins, a replacement and drops',
    () async {
      final path = '${dir.path}${Platform.pathSeparator}$endpointPinsFileName';
      final store = FileEndpointPinStore(File(path));

      await store.confirm(
        EndpointPin(
          serverId: 'srv-gamma',
          host: 'gamma.example.com',
          port: 22,
          username: 'root',
          jumpRouteIds: const [],
          confirmedAt: DateTime.utc(2026, 10, 16, 12),
        ),
      );
      await store.confirm(
        EndpointPin(
          serverId: 'srv-beta',
          host: 'fd00::7',
          port: 2222,
          username: '',
          jumpRouteIds: const ['srv-bastion', 'srv-inner'],
          confirmedAt: DateTime.fromMillisecondsSinceEpoch(1791892801000),
        ),
      );
      await store.confirm(
        EndpointPin(
          serverId: 'srv-alpha',
          host: 'old.example.com',
          port: 2200,
          username: 'admin',
          jumpRouteIds: const ['srv-bastion'],
          confirmedAt: DateTime.fromMillisecondsSinceEpoch(1791892802000),
        ),
      );
      await store.confirm(
        EndpointPin(
          serverId: 'srv-alpha',
          host: 'alpha.example.com',
          port: 22,
          username: 'deploy',
          jumpRouteIds: const [],
          confirmedAt: DateTime.fromMillisecondsSinceEpoch(1791892803000),
        ),
      );
      await store.drop('srv-gamma');
      await store.drop('srv-never-pinned');

      // The golden is ASCII, so reading each byte as one code unit keeps a
      // mismatch readable without decoding.
      final actual = await File(path).readAsBytes();
      expect(String.fromCharCodes(actual), _endpointPinsGolden);
    },
  );
}
