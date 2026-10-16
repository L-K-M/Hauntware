import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/catalog.dart';
import 'package:test/test.dart';

EndpointPin _pin(
  String serverId, {
  String host = 'nas.local',
  int port = 22,
  List<String> jumpRouteIds = const [],
  int confirmedAtMs = 1791892800000,
}) => EndpointPin(
  serverId: serverId,
  host: host,
  port: port,
  username: 'admin',
  jumpRouteIds: jumpRouteIds,
  confirmedAt: DateTime.fromMillisecondsSinceEpoch(confirmedAtMs),
);

Future<void> _plainWriter(File target, String contents) async {
  await target.parent.create(recursive: true);
  await target.writeAsString(contents);
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('seance_endpoint_pins_');
    file = File('${dir.path}/$endpointPinsFileName');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  List<File> quarantined() => dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('.corrupt-'))
      .toList();

  group('FileEndpointPinStore', () {
    test('a missing file is an empty store and is not created', () async {
      final store = FileEndpointPinStore(file);

      expect(await store.pinFor('srv-1'), isNull);
      await store.drop('srv-1');
      expect(await file.exists(), isFalse);
    });

    test('pins round-trip across instances', () async {
      final routed = _pin(
        'srv-2',
        host: 'fd00::7',
        port: 2222,
        jumpRouteIds: const ['srv-bastion', 'srv-inner'],
      );
      final store = FileEndpointPinStore(file);
      await store.confirm(_pin('srv-1'));
      await store.confirm(routed);

      final reloaded = FileEndpointPinStore(file);
      expect(await reloaded.pinFor('srv-1'), _pin('srv-1'));
      expect(await reloaded.pinFor('srv-2'), routed);
      expect(await reloaded.pinFor('srv-3'), isNull);
    });

    test('confirm replaces an existing pin whole', () async {
      final store = FileEndpointPinStore(file);
      await store.confirm(_pin('srv-1', jumpRouteIds: const ['srv-bastion']));
      final replacement = _pin(
        'srv-1',
        host: 'moved.example.com',
        confirmedAtMs: 1791892900000,
      );

      await store.confirm(replacement);

      expect(await store.pinFor('srv-1'), replacement);
      expect(await FileEndpointPinStore(file).pinFor('srv-1'), replacement);
    });

    test(
      'drop forgets a pin, and a missing pin is a no-op without a write',
      () async {
        var writes = 0;
        final store = FileEndpointPinStore(
          file,
          atomicWriter: (target, contents) {
            writes++;
            return _plainWriter(target, contents);
          },
        );
        await store.confirm(_pin('srv-1'));
        await store.confirm(_pin('srv-2'));

        await store.drop('srv-1');
        await store.drop('srv-missing');

        expect(writes, 3);
        expect(await store.pinFor('srv-1'), isNull);
        final reloaded = FileEndpointPinStore(file);
        expect(await reloaded.pinFor('srv-1'), isNull);
        expect(await reloaded.pinFor('srv-2'), _pin('srv-2'));
      },
    );

    test('a failed write changes neither the cache nor the file', () async {
      var failNextWrite = false;
      final store = FileEndpointPinStore(
        file,
        atomicWriter: (target, contents) async {
          if (failNextWrite) {
            failNextWrite = false;
            throw const FileSystemException('write failed');
          }
          await _plainWriter(target, contents);
        },
      );
      await store.confirm(_pin('srv-1'));
      final before = await file.readAsString();

      failNextWrite = true;
      await expectLater(
        store.confirm(_pin('srv-1', host: 'evil.example.com')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.pinFor('srv-1'), _pin('srv-1'));

      failNextWrite = true;
      await expectLater(
        store.drop('srv-1'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.pinFor('srv-1'), _pin('srv-1'));
      expect(await file.readAsString(), before);
    });

    group('a corrupt file is quarantined and the store starts empty', () {
      final valid = _pin('srv-1').toJson();
      final corrupt = <String, String>{
        'not JSON': '{"version":1,"pins":[',
        'not UTF-8': 'ÿ',
        'a list root': '[]',
        'no version': jsonEncode({'pins': <Object>[]}),
        'a string version': jsonEncode({'version': '1', 'pins': <Object>[]}),
        'version 0': jsonEncode({'version': 0, 'pins': <Object>[]}),
        'no pins list': jsonEncode({'version': 1, 'pins': <String, Object>{}}),
        'a malformed entry': jsonEncode({
          'version': 1,
          'pins': [
            valid,
            {...valid, 'serverId': 'srv-2', 'port': 70000},
          ],
        }),
        'a duplicate server': jsonEncode({
          'version': 1,
          'pins': [valid, valid],
        }),
      };

      for (final MapEntry(key: name, value: contents) in corrupt.entries) {
        test(name, () async {
          if (name == 'not UTF-8') {
            await file.writeAsBytes([0x7b, 0xff, 0xfe, 0x7d]);
          } else {
            await file.writeAsString(contents);
          }
          final original = await file.readAsBytes();

          final store = FileEndpointPinStore(file);
          expect(await store.pinFor('srv-1'), isNull);

          final rescued = quarantined();
          expect(rescued, hasLength(1));
          expect(await rescued.single.readAsBytes(), original);
          expect(await file.exists(), isFalse);

          // The recovery write starts a clean document.
          await store.confirm(_pin('srv-3'));
          expect(
            await FileEndpointPinStore(file).pinFor('srv-3'),
            _pin('srv-3'),
          );
          expect(await FileEndpointPinStore(file).pinFor('srv-1'), isNull);
          expect(quarantined(), hasLength(1));
        });
      }
    });

    test('a newer version is left as it is and refuses changes', () async {
      final newer = jsonEncode({
        'version': 2,
        'pins': [
          {'serverId': 'srv-1', 'shape': 'from the future'},
        ],
      });
      await file.writeAsString(newer);
      var writes = 0;
      final store = FileEndpointPinStore(
        file,
        atomicWriter: (target, contents) {
          writes++;
          return _plainWriter(target, contents);
        },
      );

      expect(await store.pinFor('srv-1'), isNull);
      await expectLater(
        store.confirm(_pin('srv-1')),
        throwsA(
          isA<EndpointPinsNewerVersionException>().having(
            (e) => e.version,
            'version',
            2,
          ),
        ),
      );
      await expectLater(
        store.drop('srv-1'),
        throwsA(isA<EndpointPinsNewerVersionException>()),
      );

      expect(writes, 0);
      expect(quarantined(), isEmpty);
      expect(await file.readAsString(), newer);
    });

    test('an unreadable file fails the call and is read again later', () async {
      // A directory at the file's path cannot be read as a file.
      await Directory(file.path).create();
      final store = FileEndpointPinStore(file);

      await expectLater(
        store.pinFor('srv-1'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await Directory(file.path).exists(), isTrue);
      expect(quarantined(), isEmpty);

      await Directory(file.path).delete();
      await File(file.path).writeAsString(
        jsonEncode({
          'version': 1,
          'pins': [_pin('srv-1').toJson()],
        }),
      );
      expect(await store.pinFor('srv-1'), _pin('srv-1'));
    });

    test('mutations run one at a time in call order', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final written = <String>[];
      final store = FileEndpointPinStore(
        file,
        atomicWriter: (target, contents) async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          // Yield so an unserialized mutation would overlap this write.
          await Future<void>.delayed(const Duration(milliseconds: 2));
          await _plainWriter(target, contents);
          written.add(contents);
          inFlight--;
        },
      );

      final operations = <Future<void>>[
        for (var i = 0; i < 10; i++) store.confirm(_pin('srv-$i')),
        store.drop('srv-3'),
        store.confirm(_pin('srv-5', host: 'moved.example.com')),
        store.drop('srv-7'),
      ];
      final lookup = store.pinFor('srv-5');
      await Future.wait(operations);

      expect(maxInFlight, 1);
      expect(written, hasLength(13));
      expect((await lookup)!.host, 'moved.example.com');

      final reloaded = FileEndpointPinStore(file);
      for (var i = 0; i < 10; i++) {
        final pin = await reloaded.pinFor('srv-$i');
        switch (i) {
          case 3 || 7:
            expect(pin, isNull, reason: 'srv-$i');
          case 5:
            expect(pin, _pin('srv-5', host: 'moved.example.com'));
          default:
            expect(pin, _pin('srv-$i'), reason: 'srv-$i');
        }
      }
    });

    test('a failed mutation does not stall the ones queued after it', () async {
      var failFirst = true;
      final store = FileEndpointPinStore(
        file,
        atomicWriter: (target, contents) async {
          if (failFirst) {
            failFirst = false;
            throw const FileSystemException('write failed');
          }
          await _plainWriter(target, contents);
        },
      );

      final failed = store.confirm(_pin('srv-1'));
      final next = store.confirm(_pin('srv-2'));

      await expectLater(failed, throwsA(isA<FileSystemException>()));
      await next;
      expect(await store.pinFor('srv-1'), isNull);
      expect(await store.pinFor('srv-2'), _pin('srv-2'));
    });
  });
}
